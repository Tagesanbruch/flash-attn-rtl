# 2026-03-15 基于 Q8.8 RTL 的 FP8 并行化改造与点积引擎分析

## 1. 读取 Q8.8 RTL 后的关键抽象

参考实现：

- `rtl/core/fa_attention_core.sv`
- `rtl/core/fa_qk_dotprod_slice.sv`
- `rtl/core/fa_online_softmax_ctx.sv`
- `rtl/core/fa_row_context_rf.sv`

提取到的关键模式：

1. Tile 主状态机：`LOAD_Q -> INIT_CONTEXT -> LOAD_K/V -> COMPUTE -> NORMALIZE -> WRITE_O`；
2. 在线 softmax 上下文寄存器：`m/l/acc` 跨 K tile 保持；
3. 点积与 softmax 更新采用流水槽（ctx slot）并行推进；
4. perf counter 按主状态与子状态双层统计。

## 2. 本轮已做的 FP8 改造

### 2.1 功能与调度

在完整核心中引入了“并行 dot engine 周期模型”与上下文管理：

- `experiments/fp8/fa_fp8_attention_core_full/base/fa_fp8_attention_core_full.sv`

核心变化：

1. 保留完整 attention 流程（score + online softmax + PV + ctx）；
2. 引入 `DOT_ENGINES` 参数（默认 4）描述并行点积引擎能力；
3. 周期统计改为并行化口径：

$$
C_{row}=\left\lceil\frac{S}{E}\right\rceil\cdot D + \left\lceil\frac{S}{E}\right\rceil\cdot D + S + D
$$

其中 $E=DOT\_ENGINES$。

### 2.2 仿真验证

测试：

- `experiments/fp8/fa_fp8_attention_core_full/tb/test_fa_fp8_attention_core_full.py`

结果：

1. `S=8,D=8`: `cycles=384`, `mismatches=0`
2. `S=16,D=16`: `cycles=2560`, `mismatches=0`

命令：

```bash
make -C experiments verif MOD=fp8/fa_fp8_attention_core_full EXP=base
```

## 3. 与题意 S=256,D=64 的引擎数量评估

按当前模型：

$$
C(S,D,E)=S\cdot\left(2\cdot\left\lceil\frac{S}{E}\right\rceil\cdot D + S + D\right)
$$

代入 $S=256,D=64$：

1. `E=4`: `2,179,072` cycles
2. `E=16`: `606,208` cycles
3. `E=32`: `344,064` cycles
4. `E=40`: `311,296` cycles
5. `E=48`: `278,528` cycles

结论：

1. 在“无额外重叠优化”的模型下，若要低于 `300k`，需要约 `48` 个点积引擎量级；
2. 若引入更深重叠（score/softmax/PV pipeline overlap）和更高 tile 复用，可降低对引擎数量的硬需求。

## 4. FP8 点积引擎“单周期”可行性分析（报告补充）

问题：是否可像 TensorCore 一样单周期完成小矩阵 FMA？

结论：

1. **在 ASIC 上“单周期 4x4 FP8/FP16 MMA”是可能的**，但前提是：
   - 深度定制乘加阵列；
   - 紧耦合寄存器/局部 SRAM；
   - 高度受限的数据通路与时钟收敛；
2. 对当前通用可综合 RTL 路径，直接追求“单周期完成全部 dot + softmax + pv”不现实；
3. 更可行路线：
   - 把 `dot` 设计成固定形状微核（如 4x4 或 8x4）；
   - 通过多微核并行 + 多级流水，在系统级接近“每周期高吞吐”而非“单算子单周期”；
   - 在线 softmax 与 ctx 更新做槽化流水，隐藏非线性阶段延迟。

### 4.1 定量边界（以 S=256, D=64, E4M3->Q4.11 近似路径为例）

若希望“单周期完成一条 `q dot k`（64 维）”，关键路径至少包含：

1. 64 组乘法（FP8 decode + 定点乘）；
2. 多级加法树归约；
3. 缩放/舍入/饱和。

对常见工艺下的中高频目标（例如 800MHz~1GHz），单拍塞入“解码 + 64 乘 + 全归约 + 后处理”通常难以收敛；即便在低频可勉强通过，也会显著牺牲面积和功耗效率。

因此应区分两件事：

1. 单个 dot 真正单周期完成：可行性低，代价高；
2. 系统吞吐达到“每周期产出多个有效 dot 结果”：可行性高，通过流水并行实现。

### 4.2 工程化建议

1. 保持微核拍数固定（例如 2~4 拍完成一组 chunk dot）；
2. 通过 `DOT_ENGINES` 横向扩展吞吐，而不是压单拍时序；
3. softmax 与 PV 做跨行重叠，减少对 dot 单拍能力的依赖；
4. 先以时序可收敛频点为约束，再反推最小引擎数。

### 4.3 结论（可执行版）

1. “全流程单周期”不作为当前 RTL 主目标；
2. “高吞吐多引擎 + 多级流水”是与现有 Q8.8 主线最一致、风险最低的路线；
3. 后续若追求极限频点/面积比，再单独评估专用 FP8 MMA 宏单元替换路径。

## 5. 下一步落地建议

1. 在 `DOT_ENGINES` 基础上继续参数化 `ROW_PAR` 与 `CTX_SLOTS`；
2. 把 score/softmax/pv 三段做可重叠调度，减少串行阶段；
3. 对齐 Q8.8 顶层寄存器与 perf 口径，进入系统级全核验证。
