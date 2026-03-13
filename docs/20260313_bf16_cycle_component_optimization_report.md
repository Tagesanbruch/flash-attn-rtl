# 20260313 BF16 顶层周期/组件优化分析报告（架构→组件）

## 1. 目标与输入口径

本报告聚焦当前 `fa_attention_core_bf16fp32` 路径，回答三个问题：

1. 当前周期主要花在哪里（架构/组件分解）；
2. 与 Int 主线相比，量级差距来自哪里；
3. 在保持当前接口边界前提下，哪些优化最值得优先做（给出定量收益）。

数据来源：

- 第一轮修复后回归日志：
  - `logs/bf16_module_ae/fa_attention_core_noncausal_fix1.log`
  - `logs/bf16_module_ae/fa_attention_core_causal_fix1.log`
  - `logs/bf16_module_ae/fa_attention_core_trace_noncausal_fix1.log`
  - `logs/bf16_module_ae/fa_attention_core_trace_causal_fix1.log`
- 修复前对照日志：
  - `logs/bf16_module_ae/fa_attention_core_noncausal_bitaccurate_ref.log`
  - `logs/bf16_module_ae/fa_attention_core_trace_noncausal.log`
  - `logs/bf16_module_ae/fa_attention_core_trace_causal.log`
- Int 主线周期基线：`docs/20260310_current_cycle_perf_and_accuracy_analysis.md`

---

## 2. BF16 当前周期分解（实测）

### 2.1 顶层实测摘要

来自 `fa_attention_core_noncausal_fix1.log` 与 `fa_attention_core_causal_fix1.log`：

- `cycles = 8,573,025`
- noncausal: `MAE = 0.000000`, `MaxAE = 0.000000`
- causal: `MAE = 0.000000`, `MaxAE = 0.000000`
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

softmax 侧进一步优化（4-lane）后的实测（`fa_attention_core_noncausal_softmax4.log` / `fa_attention_core_causal_softmax4.log`）：

- noncausal: `cycles = 3,330,145`, `MAE = 0.000000`, `MaxAE = 0.000000`
- causal: `cycles = 3,330,145`, `MAE = 0.000000`, `MaxAE = 0.000000`
- `perf compute`:
  - `dp_run = 2,097,152`
  - `score_done = 65,536`
  - `softmax_prep = 1,048,576`

dot/sm 控制重叠原型（fold `S_NEXT_PAIR` 到 `S_ACC_UPDATE`）后的实测（`fa_attention_core_noncausal_overlap1.log` / `fa_attention_core_causal_overlap1.log`）：

- noncausal: `cycles = 3,264,609`, `MAE = 0.000000`, `MaxAE = 0.000000`
- causal: `cycles = 3,264,609`, `MAE = 0.000000`, `MaxAE = 0.000000`
- `perf compute`:
  - `dp_run = 2,097,152`
  - `score_done = 65,536`
  - `softmax_prep = 1,048,576`
  - `compute = 3,211,264`

细粒度 counter 实测（`fa_attention_core_noncausal_finecounter.log` / `fa_attention_core_causal_finecounter.log`）：

- `lane_idle = 0`
- `ctx_wait = 0`
- `tile_switch_bubbles = 24`

修复前后对比（noncausal）：

| 版本 | MAE | MaxAE | 首分歧 | 结论 |
|---|---:|---:|---|---|
| 修复前 | 0.016175 | 0.094727 | `q=0,k=128` | 失败 |
| 修复后（fix1） | 0.000000 | 0.000000 | 无 | 通过 |

### 2.2 占比

以总周期 `8,573,025` 计算：

- `compute`: `8,519,680`（`99.3778%`）
- `load_k`: `16,416`（`0.1915%`）
- `load_v`: `16,416`（`0.1915%`）
- `norm`: `16,384`（`0.1911%`）
- `load_q`: `2,056`（`0.0240%`）
- `write_o`: `2,056`（`0.0240%`）

结论：**瓶颈极端集中于 compute 状态，任何搬运/写回优化上限都很低（<1% 级别）**。

优化后（softmax 4-lane）按总周期 `3,330,145` 计算：

- `compute`: `3,276,800`（`98.3981%`）
- 非 compute 合计：`53,345`（`1.6019%`）

说明：compute 仍是绝对主瓶颈，但“固定非compute开销”占比已抬升，后续再提速会更受 Amdahl 限制。

### 2.3 第一轮修复内容与定位

根因并非 RTL 算法状态机，而是 top-core cocotb 测试基址配置重叠：

- 修复前：`Q/K/V/O` 基址区间互相覆盖；
- 结果：在 tile 边界（`k=128` 或 `q=128`）首次读到被覆盖数据，触发 score 首分歧；
- 修复后：将四段地址改为不重叠大间隔，并新增 `assert_non_overlapping_regions` 运行前检查。

因此，本轮已完成“正确性阻塞项清零”，后续可以专注周期优化。

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

### 3.3 更细化的 compute 组成

对每个 `(q,k)` pair，当前可抽象为：

$$
C_{pair}=C_{dot}+C_{sm}+C_{ovh}=64+64+2=130.
$$

其中：

- `C_dot`：`D=64` 的串行 dot 累加；
- `C_sm`：softmax/acc 路径按 `D=64` 串行更新；
- `C_ovh`：状态切换与尾拍固定开销（每 pair 约 2 拍）。

推广为并行度参数模型：

$$
C_{pair}(P_{dot},P_{sm})=\left\lceil\frac{64}{P_{dot}}\right\rceil + \left\lceil\frac{64}{P_{sm}}\right\rceil + 2.
$$

总周期近似：

$$
C_{total}\approx 65,536\cdot C_{pair}(P_{dot},P_{sm}) + 53,345.
$$

本次实测对应：`P_dot=2`, `P_sm=4`，因此

$$
C_{pair}=\lceil 64/2 \rceil + \lceil 64/4 \rceil + 2 = 50,
$$

$$
C_{total}=65,536\times 50 + 53,345 = 3,330,145,
$$

与实测完全一致。

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

## 5. 正确性状态（第一轮修复后）

第一轮修复后 trace 结论：

- noncausal：`trace_first_score_divergence = none`；
- causal：`trace_first_score_divergence = none`；
- `trace_index_alignment = pass`；
- `max_score_ae/max_m_ae/max_l_ae/max_inv_ae` 全为 `0.000000`。

结论：跨 tile 首分歧已闭环，compute 优化可进入实现阶段。

但建议保留两条防回归护栏：

1. 保留 DMA 区间不重叠断言；
2. 保留 trace testcase 作为并行化后的强回归项。

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

### 6.5 compute 细化优化建议（组件级）

按“收益/实现复杂度”排序：

1. **优先级 P0：dot 2-lane（低风险高收益）**
  - 把 `C_dot` 从 `64` 降到 `32`；
  - 在不改 softmax 的情况下即可拿到约 `1.324x`。

2. **优先级 P1：softmax 2-lane（与 P0 叠加）**
  - 把 `C_sm` 从 `64` 降到 `32`；
  - 与 P0 叠加后可到约 `1.958x`。

3. **优先级 P2：dot/softmax 子阶段重叠（架构优化）**
  - 目标是把“加法关系”逼近“max关系”：

$$
C_{pair}\approx \max(C_{dot}, C_{sm}) + C_{ovh}.
$$

  - 若 `P_dot=P_sm=2` 且重叠理想，pair 周期可从 `66` 继续逼近 `34` 附近，进入 3x 级空间。

4. **优先级 P3：4-lane 扩展（中期）**
  - 需要处理面积、布线、时序与功耗，不建议作为第一批提交目标。

### 6.6 本轮完成情况（dot+softmax）

相对 `fix1`（`8,573,025` cycles）实测收益：

$$
	ext{Speedup}=\frac{8,573,025}{3,330,145}\approx 2.574\times,
$$

总周期下降：

$$
8,573,025-3,330,145=5,242,880\ (\approx 61.16\%).
$$

关键计数变化：

- `dp_run`: `4,194,304 -> 2,097,152`（-50%）
- `softmax_prep`: `4,194,304 -> 1,048,576`（-75%）
- `score_done`: 保持 `65,536`

这与“dot 2-lane + softmax 4-lane”的结构目标一致，且精度未退化（MAE/MaxAE 维持 0）。

### 6.7 细粒度 counter 分析

新增指标定义：

1. `lane_idle`：计算状态中出现 lane 尾部空转的周期数；
2. `ctx_wait`：上下文相关等待周期数（当前实现下为0）；
3. `tile_switch_bubbles`：`k_tile` 切换时的显式气泡周期。

本次实测解释：

- `lane_idle = 0`：当前 `D=64` 与 lane 配置（dot=2, softmax=4）整除，无尾部浪费；
- `ctx_wait = 0`：当前 datapath 未引入显式 ctx 等待状态；
- `tile_switch_bubbles = 24`：

$$
	ext{NUM\_Q\_TILES}\times(\text{NUM\_K\_TILES}-1)=8\times(4-1)=24.
$$

该值与架构推导完全一致，且在总周期中的占比仅：

$$
24/3,330,145\approx 0.00072\%.
$$

结论：当前版本里，真正值得继续投入的是 compute 主路径重叠，而非 tile 切换微优化。

### 6.8 重叠原型收益复盘

从 softmax4 版本（`3,330,145`）到 overlap1（`3,264,609`）：

$$
3,330,145 - 3,264,609 = 65,536
$$

恰好等于全局 pair 数 `256×256`，说明本次原型准确消除了“每pair 1拍控制气泡”。

相对 fix1（`8,573,025`）总加速达到：

$$
\frac{8,573,025}{3,264,609}\approx 2.626\times.
$$

同时 `MAE/MaxAE` 保持 `0`，证明该重叠方式在当前参数下可稳定成立。

### 6.9 dot 4-lane 实验结果

在 overlap1 基础上把 dot 从 2-lane 提升到 4-lane，实测日志：

- `fa_attention_core_noncausal_dot4.log`
- `fa_attention_core_causal_dot4.log`

核心结果（noncausal/causal一致）：

- `cycles = 2,216,033`
- `MAE = 0.000000`
- `MaxAE = 0.000000`
- `compute = 2,162,688`
- `dp_run = 1,048,576`
- `softmax_prep = 1,048,576`
- `lane_idle = 0`, `ctx_wait = 0`, `tile_switch_bubbles = 24`

与上一版对比：

1. 相对 overlap1（`3,264,609`）

$$
	ext{Speedup}=\frac{3,264,609}{2,216,033}\approx 1.473\times.
$$

2. 相对 fix1（`8,573,025`）

$$
	ext{Speedup}=\frac{8,573,025}{2,216,033}\approx 3.869\times.
$$

3. 相对 softmax4（`3,330,145`）

$$
3,330,145-2,216,033=1,114,112.
$$

解释：`dp_run` 与 `softmax_prep` 已完全对齐（都为 `1,048,576`），当前 compute 已进入“dot/softmax 双主路径均衡”状态。后续要继续显著下降，需要做真正的跨pair流水重叠，而不是单侧继续加lane。

### 6.10 pipeline v1（SCORE_APPLY 与 ACC 首拍融合）结果

为进一步逼近跨pair流水，先实现安全的一阶段：把 `S_SCORE_APPLY` 与 `S_ACC_UPDATE` 首拍融合。

实测日志：

- `fa_attention_core_noncausal_pipev1.log`
- `fa_attention_core_causal_pipev1.log`

结果（noncausal/causal一致）：

- `cycles = 2,150,497`
- `MAE = 0.000000`, `MaxAE = 0.000000`
- `compute = 2,097,152`
- `dp_run = 1,048,576`
- `softmax_prep = 983,040`

收益：

1. 相对 dot4（`2,216,033`）

$$
2,216,033 - 2,150,497 = 65,536
$$

再次精确等于 pair 总数，说明每pair再压缩了 1 个固定拍。

2. 相对 fix1（`8,573,025`）

$$
\frac{8,573,025}{2,150,497}\approx 3.987\times.
$$

---

## 7. 架构到组件的落地路线

### Phase 0（已完成）：跨 tile 正确性收敛

结果：

- noncausal/causal 主测试均 `MAE=0, MaxAE=0`；
- trace 分歧清零。

### Phase 1（下一步）：dot 2-lane 原型

目标：`C_pair 130 -> 98`，总周期降至约 `6.48M`。

验收口径：

1. 精度仍保持 `MAE=0, MaxAE=0`（当前seed口径）；
2. `dp_run` 约减半（`4,194,304 -> 2,097,152`）；
3. `compute` 接近 `6.42M` 量级。

### Phase 2（已完成并超目标）：softmax 侧并行化

结果：从 softmax 2-lane 继续推进到 4-lane，达到 `~2.57x`（相对 fix1）。

组件建议：

1. 维持 row 语义不变，仅做 lane 化与调度重排；
2. 追加 counter：`ctx_wait_cycles`、`lane_idle_cycles`、`tile_switch_bubbles`。

### Phase 3：重叠化与更高并行探索（下一步）

目标：在精度稳定前提下进入 `>2x` 以上空间。

建议：

1. `ctx` bank 连续映射 + tag 化，减少冲突；
2. 尝试 dot/sm 子阶段重叠发射；
3. 评估 dot 侧进一步并行（4-lane）与资源/时序可行性。

---

## 8. 结论

1. 第一轮修复已闭环：主测试与trace均恢复 `MAE=0, MaxAE=0`；
2. 周期瓶颈仍高度集中于 compute（99.38%）；
3. 细化模型 `C_pair=⌈64/P_dot⌉+⌈64/P_sm⌉+2` 给出直接优化靶点；
4. 当前已验证 `dot 2-lane + softmax 4-lane` 在精度0损失下达到 `3,330,145 cycles`（`2.574x`）；
5. `dot 4-lane`后已达到 `2,216,033 cycles`（相对fix1约 `3.869x`）；
6. `pipeline v1` 进一步到 `2,150,497 cycles`（相对fix1约 `3.987x`）；
7. 下一步仍应是“真正跨pair流水重叠 + counter增强”，而非DMA微调。

建议下一步按“子阶段重叠原型 + counter增强 + trace强回归”执行。