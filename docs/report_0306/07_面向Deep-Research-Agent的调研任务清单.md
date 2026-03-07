# 07 面向 Deep-Research-Agent 的调研任务清单

本章用于给后续 deep research agent 直接提供输入。目标不是泛泛“找优化方法”，而是围绕当前主线 RTL 的**明确痛点**，拆成可执行的调研任务。

与旧版任务清单相比，这一版特别强调一件事：

- `500MHz` **不是赛题硬要求**；
- 它只是当前阶段便于横向比较的**内部拉频观察点**；
- 真正更重要的指标是端到端：

$$
\text{Latency}_{SDPA} \approx \frac{\text{cycles}}{f_{clk}}, \qquad
\text{Throughput}_{SDPA} \approx \frac{f_{clk}}{\text{cycles}}
$$

也就是说，后续调研必须避免“局部模块 Fmax 上去了，但主线 cycles 也明显变多，最终反而更慢”的伪优化。

---

## 7.1 总体要求（给所有 agent 的统一约束）

请所有后续调研都遵循以下约束：

1. 面向 **FlashAttention-style baseline**，参数固定为：
   - `S=256`
   - `d=64`
   - `batch=1`
   - `head=1`
   - causal mask
2. 必须满足：
   - 不显式存储 `S×S` 注意力矩阵；
   - online softmax；
   - K/V tiling；
   - 输入/输出 `Q8.8`；
   - 误差门限 `MAE<=0.03, MAX_AE<=0.10`；
3. 当前主线已知定量基线：
   - 当前周期：`148,656 cycles`
   - 当前外存 traffic：`589,824 bytes`
   - 当前 RTL vs FP32：`MAE=0.00291701`, `MAX_AE=0.00588431`
   - 当前主线 active-path 局部时序短板：
     - `fa_mul_sat_q8_8`：约 `432MHz`
     - `fa_exp_pwl_8seg_q1_15`：约 `399MHz`
4. 当前工程上更值得优化的目标函数是：
   - 优先最大化 $\frac{f_{clk}}{\text{cycles}}$；
   - 或等价地，最小化 $\frac{\text{cycles}}{f_{clk}}$；
   - 其次再看面积、带宽、验证复杂度。
5. 调研产出需尽量包含：
   - 方案原理；
   - 是否适合 ASIC / RTL 综合；
   - 对 cycle / area / timing / bandwidth / verification 的影响；
   - 是否有开源代码、论文、专利或工业常见实现可以借鉴；
   - 与当前 `flashattn` 项目 RTL 的结合方式。

---

## 7.2 当前必须让 agent 知道的工程事实

### 7.2.1 “500MHz” 只是观察点，不是终局目标

如果一个方案把局部模块推到 `500MHz+`，但把主线周期从 `148,656` 推高到 `250k+`，它未必是好方案。

当前 baseline 的一个直观换算是：

- 若按 `399MHz` 估算，单次 SDPA 时延约 `372.57us`；
- 若按 `500MHz` 且**周期不变**估算，单次 SDPA 时延约 `297.31us`。

所以后续 research agent 的任务，不是孤立追求“500MHz”这个数字，而是寻找**能在周期不过度恶化的前提下抬高频率**的方案。

### 7.2.2 最近算子实验给出的启发

近期在 `experiments/` 中已做过一轮“增加算子流水”的 isolated experiments：

- [experiments/fa_mul_sat_q8_8_pipe](../../experiments/fa_mul_sat_q8_8_pipe)
  - `base`：约 `503MHz`
  - `exp_a`：约 `592MHz`
- [experiments/fa_exp_pwl_8seg_q1_15_pipe](../../experiments/fa_exp_pwl_8seg_q1_15_pipe)
  - `base`：约 `457MHz`
  - `exp_b`：约 `677MHz`

这些结果说明：

1. **局部算子**确实可以靠加流水显著拉高 Fmax；
2. 但如果在当前 `fa_attention_core` 的 pair-wise 串行 FSM 中**直接等待这些流水级**，则总周期会大幅增加；
3. 因此，真正需要研究的不是“怎么给算子多塞几级寄存器”，而是：
   - 如何 hide latency；
   - 如何 overlap；
   - 如何让更深流水不等价地转化成更多 SDPA cycles。

也就是说，后续调研应把 isolated-operator pipeline 和 system-level schedule 一起考虑。

---

## 7.3 调研任务 A：如何提升整体有效吞吐，而不是只拉局部 Fmax

### 当前痛点

当前项目已经证明：

- 单看局部算子，深流水很容易让 `Fmax` 明显提升；
- 但主线微架构若不能隐藏这部分 latency，最终会损失 `cycles`；
- 于是 $\frac{\text{cycles}}{f_{clk}}$ 这个真正更关键的指标，未必会变好。

### 调研目标

请 agent 重点研究：

1. 如何定义更合理的**系统级优化目标**：
   - `Latency = cycles / f_clk`
   - `Throughput = f_clk / cycles`
   - `Area efficiency = Throughput / Area`
2. 在 attention accelerator 里，哪些结构最容易出现“局部 Fmax 变好、系统反而变慢”的情况；
3. 是否有成熟方法可以同时优化：
   - operator latency
   - schedule overlap
   - tile-level throughput
4. 是否存在适合当前项目的建模方式，能在改 RTL 前先粗估“新流水级会不会把 total cycles 拉爆”。

### 希望输出

1. 适合当前项目的 system-level 指标体系；
2. 一套“先估算再动 RTL”的评估方法；
3. 推荐的后续优化优先级：先改算子、先改调度，还是必须一起改。

---

## 7.4 调研任务 B：online softmax recurrence 如何流水化/交错化

### 当前痛点

当前 online softmax 的核心递推仍是最危险的结构性问题。历史 STA 显示相关 recurrence 型逻辑只在约 `189MHz` 量级。

递推核心是：

$$
l_i = l_{i-1}\cdot e^{m_{i-1}-m_i} + e^{x_i-m_i}
$$

$$
acc_i = acc_{i-1}\cdot e^{m_{i-1}-m_i} + e^{x_i-m_i}\cdot v_i
$$

单纯插流水会引入 data hazard。

### 调研目标

找出适合硬件实现的 **online softmax 反馈链解耦/交错/分阶段** 方案，重点回答：

1. 是否存在可综合的 **multi-context interleaving** / **wavefront** / **software-pipelined** 结构，让 pipeline latency 被多行上下文隐藏；
2. 是否存在把 `m/l/acc` 更新分裂为多个 stage，但仍维持 **II≈1** 或较高吞吐的组织方式；
3. 是否存在对 online softmax 的**等价变形**，适合硬件分段更新；
4. 是否有论文/专利/开源实现已经解决了这类 recurrence timing 问题。

### 建议关键词

- `online softmax hardware pipeline`
- `streaming softmax accelerator`
- `FlashAttention hardware online softmax`
- `interleaved recurrence pipeline`
- `softmax recurrence ASIC`
- `running max sum exp hardware`
- `attention accelerator online normalization`

### 希望输出

1. 最值得参考的 3~5 类结构；
2. 每类结构对当前项目的改造代价；
3. 是否有望显著提升 system-level throughput，而不是只提升局部 Fmax；
4. 是否会明显增加 cycles；
5. 推荐优先尝试的 1~2 个方案。

---

## 7.5 调研任务 C：`exp` / `reciprocal` / `mul-sat` 的更高频实现，但必须能被系统隐藏

### 当前痛点

- `fa_mul_sat_q8_8`：主线约 `432MHz`
- `fa_exp_pwl_8seg_q1_15`：主线约 `399MHz`
- isolated experiments 已证明：加流水可以把它们推到 `500MHz+`
- 但如果 current FSM 逐次等待这些流水级，则 total cycles 会明显上升

### 调研目标

围绕低位宽定点算子，寻找更适合 **55nm ASIC / 高频实现** 的方式，但必须同时回答“如何在主线里隐藏其额外 latency”：

1. `Q8.8 * Q8.8 -> Q8.8` 饱和乘法器是否有更好结构：
   - 更适合插 1 级/2 级流水；
   - 更适合 partial-product 重组；
   - 更利于与上层 schedule overlap。
2. `exp(x)` 是否有比当前 8 段 PWL 更好平衡的方案：
   - LUT + interpolation
   - multipartite table
   - base-2 exp / log domain
   - 更细粒度但更可流水的分段方案
3. `1/x` 是否有更利于 system integration 的实现：
   - LUT + 1-step NR
   - Goldschmidt
   - multipartite reciprocal
   - domain-restricted reciprocal
4. 对每种实现，必须回答：
   - isolated Fmax 会不会提升；
   - 额外 latency 是多少；
   - latency 能否被 current 或 modified microarchitecture 隐藏。

### 建议关键词

- `fixed-point exp ASIC softmax`
- `piecewise linear exp hardware`
- `reciprocal hardware Newton Raphson Goldschmidt`
- `saturating multiplier fixed point ASIC`
- `softmax exp approximation FPGA ASIC`

### 希望输出

1. 每类算子 2~3 种最值得比较的结构；
2. 每种结构对：
   - 时序
   - 面积
   - 误差
   - 流水深度
   - 主线周期
   的影响；
3. 哪些方案适合直接替换当前模块；
4. 哪些方案只有配合新的 overlap 调度才值得采用。

---

## 7.6 调研任务 D：如何在不显著增 cycles 的前提下降低 top 级面积

### 当前痛点

当前 top 级面积未正式闭环，且片上寄存器式缓存存在高风险。

### 调研目标

寻找 **FlashAttention baseline** 在小规模 `S=256, d=64` 下的低面积实现策略：

1. 哪些 buffer 最值得转成 SRAM / register file / single-port or dual-port SRAM；
2. 哪些上下文必须常驻、哪些可以 time-mux；
3. `TQ/TK` 是否存在更优组合，在面积、带宽、周期之间取得更好折中；
4. 是否有 attention accelerator 采用更“窄”的阵列组织，仍保持 baseline 周期在 `300k` 以内；
5. 这些结构是否同时有助于 hide 更深算子流水的 latency。

### 建议关键词

- `attention accelerator SRAM tiling area tradeoff`
- `FlashAttention ASIC SRAM buffer architecture`
- `attention accelerator local memory hierarchy`
- `tile size attention hardware area bandwidth`
- `systolic attention low area`

### 希望输出

1. 对当前 `q_buf / k_buf / v_buf / row_acc / o_buf` 哪些应该 SRAM 宏化，给出优先级；
2. 给出可能的 `TQ/TK/ROW_PAR/DP_LANES` 调参方向；
3. 判断有没有机会在面积显著下降的同时仍维持 `<300k cycles`；
4. 判断这些变化对 `f_clk / cycles` 是否净正收益。

---

## 7.7 调研任务 E：K/V 带宽复用的更优方案

### 当前痛点

当前 baseline 一次 attention 的主存 traffic 约 **589,824 bytes**，K/V 重读占主导。

### 调研目标

研究是否有适合当前规模和题目约束的 K/V 复用方案：

1. 更大 tile / 多级 tile / streaming reuse；
2. K/V 全量缓存或半缓存的收益与面积代价；
3. 是否有折中的 line buffer / banked SRAM / row-stationary 组织；
4. 如何在不存储 `S×S` 的前提下进一步减少 K/V 外部 traffic；
5. 降低带宽后，是否也能反过来帮助时钟收敛与整体能效。

### 建议关键词

- `attention accelerator KV reuse buffer`
- `FlashAttention hardware bandwidth optimization`
- `row stationary attention accelerator`
- `KV cache on-chip attention hardware`

### 希望输出

1. 几种可在 baseline 上落地的 K/V 复用方案；
2. 每种方案带来的：
   - RD_BYTES 减少比例
   - SRAM 增量
   - 时序压力变化
   - 主线周期变化
3. 推荐的最现实方案。

---

## 7.8 调研任务 F：是否存在更适合 baseline 的整体微架构

### 当前痛点

当前架构能过功能、误差、周期红线，但频率、面积与 system-level throughput 都还不够稳妥。

### 调研目标

不是只看单个模块，而是查找：

1. baseline `S=256, d=64` 下，业界/学界有没有更适合的 attention microarchitecture；
2. 是否有已经公开的：
   - ASIC attention core
   - FlashAttention-style accelerator
   - streaming softmax hardware
   - low-area transformer attention IP
3. 哪些设计天然更容易把深流水算子隐藏掉；
4. 哪些设计能在 `cycles`、`f_clk`、`area` 三者间给出更好的平衡。

### 建议关键词

- `ASIC attention accelerator baseline 256x64`
- `FlashAttention hardware open source RTL`
- `transformer attention accelerator ASIC`
- `streaming attention accelerator SRAM`
- `softmax fused attention hardware`

### 希望输出

1. 3~5 个最接近本项目约束的参考设计；
2. 它们的核心思想；
3. 哪些思想可嫁接到当前项目；
4. 哪些会破坏当前 baseline 约束，不建议采用；
5. 哪些最有希望提高 `f_clk / cycles`。

---

## 7.9 调研任务 G：实现与物理层面的收敛技巧

### 当前痛点

即使架构改好，最后仍要落到 55nm 工艺的综合/STA/P&R。

### 调研目标

查找对这类中等规模算术核常用的物理收敛策略：

1. register retiming / logic restructuring / multi-bit flop / clock gating 的使用经验；
2. 对 RAM-heavy / datapath-heavy attention accelerator 的 floorplan 建议；
3. 是否有对 recurrence-heavy datapath 适用的 CTS / placement 经验；
4. 哪些技巧能够帮助深流水算子更自然地融入 top，而不只是 isolated module 好看。

### 建议关键词

- `ASIC datapath timing closure recurrence`
- `attention accelerator physical design`
- `softmax datapath timing closure`
- `register retiming arithmetic pipeline ASIC`

### 希望输出

1. 哪些技巧适合当前项目；
2. 哪些属于“实现修饰”，不能替代架构修改；
3. 推荐的后续 STA/P&R 试验顺序。

---

## 7.10 建议给 agent 的统一输出格式

建议要求每个 deep research agent 最终按以下格式输出：

1. **问题定义**：当前项目的具体瓶颈是什么；
2. **外部参考列表**：论文 / 专利 / 开源工程 / 工业博客；
3. **候选方案对比表**：
   - 原理
   - 时序潜力
   - 面积影响
   - 周期影响
   - 吞吐影响
   - 误差影响
   - RTL 实施复杂度
4. **最推荐方案**：1~2 个；
5. **落地建议**：如何映射到 `flashattn` 当前 RTL；
6. **风险点**：验证、对齐、误差、接口、存储等。

---

## 7.11 本章结论

如果要把当前项目从“baseline 已可运行、功能/误差/周期已过线”推进到“更像可提交的完整高质量工程版本”，下一阶段最值得调研的方向是：

1. **先把 system-level 目标从“500MHz”改成“最大化 `f_clk / cycles`”**；
2. **online softmax recurrence 的新微架构**；
3. **`exp / reciprocal / mul` 的更高频实现 + latency hiding**；
4. **top 存储层级与 SRAM 宏化**；
5. **K/V 带宽复用**；
6. **更适合 baseline 的整体 attention 微架构**；
7. **后端实现层面的收敛套路**。

建议优先把任务 A、B、C、D 先交给 deep research agent，因为这四项最直接决定：

- 能否把局部拉频真正转化为端到端吞吐提升；
- 能否避免“模块变快了，系统却变慢了”；
- 能否在周期、频率、面积之间找到更可提交的平衡点。
