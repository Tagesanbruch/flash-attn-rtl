# 20260313 BF16 顶层周期/组件优化分析报告（架构→组件）

## 1. 目标与输入口径

本报告聚焦当前 `fa_attention_core_bf16fp32` 路径，回答三个问题：

1. 当前周期主要花在哪里（架构/组件分解）；
2. 与 Int 主线相比，量级差距来自哪里；
3. 在保持当前接口边界前提下，哪些优化最值得优先做（给出定量收益）。

数据来源：

- BF16 noncausal bit-accurate 运行日志：`logs/bf16_module_ae/fa_attention_core_noncausal_bitaccurate_ref.log`
- BF16 trace 首个分歧日志：
  - `logs/bf16_module_ae/fa_attention_core_trace_noncausal.log`
  - `logs/bf16_module_ae/fa_attention_core_trace_causal.log`
- Int 主线周期基线：`docs/20260310_current_cycle_perf_and_accuracy_analysis.md`

---

## 2. BF16 当前周期分解（实测）

### 2.1 顶层实测摘要

来自 `fa_attention_core_noncausal_bitaccurate_ref.log`：

- `cycles = 8,573,025`
- `MAE = 0.016175`
- `MaxAE = 0.094727`
- `state cycles`:
  - `load_q = 2,056`
  - `init = 8`
  - `load_k = 16,416`
  - `load_v = 16,416`
  - `compute = 8,519,680`
  - `norm = 16,384`
  - `write_o = 2,056`
  - `next_q = 8`
- `compute perf`:
  - `dp_run = 4,194,304`
  - `score_done = 65,536`
  - `softmax_prep = 4,194,304`
  - `comp_launch = 65,536`
  - `recip_req/rsp = 65,536`

### 2.2 占比

以总周期 `8,573,025` 计算：

- `compute`: `8,519,680`（`99.3778%`）
- `load_k`: `16,416`（`0.1915%`）
- `load_v`: `16,416`（`0.1915%`）
- `norm`: `16,384`（`0.1911%`）
- `load_q`: `2,056`（`0.0240%`）
- `write_o`: `2,056`（`0.0240%`）

结论：**瓶颈极端集中于 compute 状态，任何搬运/写回优化上限都很低（<1% 级别）**。

---

## 3. 计算环路的结构化拆解

### 3.1 pair 级周期模型（由实测反推）

当前参数：`SEQ=256, D=64`，总 pair 数：

$$
N_{pair}=256\times 256=65,536.
$$

实测 `compute = 8,519,680`，故每个 pair 周期：

$$
C_{pair}=\frac{8,519,680}{65,536}=130.
$$

结合 counter：

- `dp_run = 4,194,304 = 65,536 × 64`
- `softmax_prep = 4,194,304 = 65,536 × 64`
- 额外开销：

$$
130 - 64 - 64 = 2.
$$

因此可写为：

$$
C_{pair}=C_{dot}(64)+C_{softmax}(64)+C_{ovh}(2).
$$

### 3.2 对总周期的控制力

非 compute 周期总和：

$$
C_{other}=8,573,025-8,519,680=53,345.
$$

即使 compute 大幅下降，`C_other` 仍是最终下限。

---

## 4. 与 Int 主线的量级对比

Int 主线（`docs/20260310_current_cycle_perf_and_accuracy_analysis.md`）给出的代表性口径：

- `cycles = 85,928`
- `dp = 66,560`
- `score = 32,768`
- `softmax = 32,768`

与 BF16 当前对比：

1. 总周期比：

$$
\frac{8,573,025}{85,928}\approx 99.77\times.
$$

2. 仅 compute 维度（用 Int 的 `dp+score+softmax=132,096` 近似）对比：

$$
\frac{8,519,680}{132,096}\approx 64.5\times.
$$

解释：

- BF16 当前实现在 pair 维度近似“按 D 串行两遍（dot + softmax）”推进；
- Int 主线已通过批化/重叠/上下文交错把很多延迟折叠进更粗粒度 pipeline；
- 因此差距的主因不是 DMA，而是 **compute 内核并行度与重叠度**。

---

## 5. 正确性约束（优化前必须锁定）

当前 trace 结论：

- noncausal 首个 score 分歧：`q=0, k=128`；
- causal 首个 score 分歧：`q=128, k=0`；
- 都出现在 tile 边界切换点；
- noncausal 已验证 `index_alignment: pass`，说明软件索引映射不是主因。

这意味着：

1. 先修复边界状态一致性（score/m/l/inv 的跨 tile 传递）；
2. 再做激进并行化，否则会把误差传播放大并增加 debug 难度。

---

## 6. 优化机会与量化收益

以下估算以当前实测为基准，默认 `C_other=53,345` 不变。

### 6.1 机会 A：dot 或 softmax 单侧 2 路并行

假设：

- `C_dot: 64 -> 32`（或 `C_softmax: 64 -> 32`）
- `C_pair: 130 -> 98`

则：

- `compute = 6,422,528`
- `total = 6,475,873`
- 相对当前加速：

$$
\text{Speedup}=\frac{8,573,025}{6,475,873}\approx 1.324\times.
$$

### 6.2 机会 B：dot + softmax 双侧 2 路并行

假设：

- `C_dot: 64 -> 32`
- `C_softmax: 64 -> 32`
- `C_pair: 130 -> 66`

则：

- `compute = 4,325,376`
- `total = 4,378,721`
- 相对当前加速：

$$
\text{Speedup}\approx 1.958\times.
$$

### 6.3 机会 C：dot + softmax 双侧 4 路并行（中期）

假设：

- `C_dot: 64 -> 16`
- `C_softmax: 64 -> 16`
- `C_pair: 130 -> 34`

则：

- `compute = 2,228,224`
- `total = 2,281,569`
- 相对当前加速：

$$
\text{Speedup}\approx 3.758\times.
$$

### 6.4 机会 D：内存与归一化路径优化（次优先）

即使把 `load_k + load_v + norm + load_q + write_o` 全部压到 0（理论上不可能），上限也仅：

$$
16,416+16,416+16,384+2,056+2,056=53,328
$$

占总周期约 `0.622%`。因此这类优化可做，但**不应作为主线提速抓手**。

---

## 7. 架构到组件的落地路线

### Phase 0（必须先做）：跨 tile 正确性收敛

目标：把 `MAE/MaxAE` 从当前 `0.016175/0.094727` 拉回到可收敛区间。

建议检查点（优先级从高到低）：

1. `k_tile` / `q_tile` 切换瞬间的 `score_bf16` 采样与对齐时序；
2. `m/l/inv` 上下文读写时机（写回拍与下一拍读取是否存在 off-by-one）；
3. `softmax_update_scalar` 输入是否在边界拍被旧值覆盖；
4. 边界拍掩码（causal/noncausal）与 score valid 的握手条件。

### Phase 1：bf engine 内核并行化（主收益）

目标：先达成机会 A/B（1.32x~1.96x）。

组件建议：

1. dot 内核：
   - 将 `D=64` 的串行 MAC 改为 2-lane（后续可扩到 4-lane）；
   - 保持每拍吞吐提高，优先不改外部接口宽度。
2. softmax 路径：
   - `exp/mul/acc` 采用双上下文交错发射，减少每 pair 的串行等待；
   - 对 `recip` 维持 pipeline 化吞吐，不在单 pair 内等待 round-trip。

### Phase 2：ctx 组织优化（稳定提速 + 可扩展性）

目标：把并行收益稳定兑现到 tile 全程，避免“局部快、边界慢”。

建议：

1. `ctx` bank 从“功能分组”转为“按 row-pair 连续映射”，减少 bank conflict；
2. 边界切换时引入显式 `ctx_epoch/tag`，防止旧上下文误用；
3. 用 perf counter 增加 `ctx_wait_cycles`、`tile_switch_bubbles` 便于定量归因。

---

## 8. 结论

1. 当前 BF16 周期瓶颈是 compute（99.38%），不是搬运；
2. 现有 pair 级模型是 `64 + 64 + 2`，决定了总周期量级；
3. 若仅做单侧 2 路并行，预期约 `1.32x`；双侧 2 路约 `1.96x`；
4. 在推进并行化前，必须先修复 tile 边界 score/state 分歧，否则性能优化会放大验证成本。

建议下一步按“正确性收敛 → 双侧2路原型 → counter闭环复盘”执行。