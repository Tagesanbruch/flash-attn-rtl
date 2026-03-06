# 07 面向 Deep-Research-Agent 的调研任务清单

本章用于给后续 deep research agent 直接提供输入。目标不是泛泛“找优化方法”，而是围绕当前主线 RTL 的**明确痛点**，拆成可执行的调研任务。

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
3. 研究重点是：
   - 如何把当前约 `189MHz` 的核心瓶颈推向更高频率；
   - 同时不显著破坏当前 `148,656 cycles` 的 baseline 周期优势；
   - 并尽量降低 top 级面积与带宽压力；
4. 调研产出需尽量包含：
   - 方案原理；
   - 是否适合 ASIC / RTL 综合；
   - 对 cycle / area / timing / bandwidth / verification 的影响；
   - 是否有开源代码、论文、专利或工业常见实现可以借鉴；
   - 与当前 `flashattn` 项目 RTL 的结合方式。

---

## 7.2 调研任务 A：online softmax recurrence 如何流水化/交错化

### 当前痛点

当前 `fa_online_softmax_update` 约 **189MHz**，核心是强反馈递推：

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

请 agent 最终给出：

1. 最值得参考的 3~5 类结构；
2. 每类结构对当前项目的改造代价；
3. 是否有望把约 190MHz 提升到接近 500MHz；
4. 是否会明显增加 cycles；
5. 推荐优先尝试的 1~2 个方案。

---

## 7.3 调研任务 B：`exp` / `reciprocal` / `mul-sat` 的更适合 500MHz 的实现

### 当前痛点

- `fa_mul_sat_q8_8`：约 432MHz
- `fa_exp_pwl_8seg_q1_15`：约 399MHz
- `fa_recip_nr_q16_16`：约 501MHz，但 margin 很小

### 调研目标

围绕低位宽定点算子，寻找更适合 **55nm ASIC / 500MHz** 的实现方式：

1. `Q8.8 * Q8.8 -> Q8.8` 饱和乘法器是否有更好结构：
   - 更适合插 1 级/2 级流水；
   - 更适合 DSP-like partial product 组织；
   - 更好综合映射。
2. `exp(x)` 对于 softmax 路径，是否有比当前 8 段 PWL 更好平衡的方案：
   - LUT + interpolation
   - multipartite table
   - base-2 exp / log domain
   - shift-add / CORDIC-like / Mitchell-like 近似
3. `1/x` 是否有比当前 10 级 NR 更稳妥或更省面积的实现：
   - LUT + 1-step NR
   - Goldschmidt
   - multipartite reciprocal
   - domain-restricted reciprocal

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
   的影响；
3. 哪些方案最适合直接替换当前 `flashattn` 项目里的模块。

---

## 7.4 调研任务 C：如何在不显著增 cycles 的前提下降低 top 级面积

### 当前痛点

当前 top 级面积未正式闭环，且片上寄存器式缓存存在高风险。

### 调研目标

寻找 **FlashAttention baseline** 在小规模 `S=256, d=64` 下的低面积实现策略：

1. 哪些 buffer 最值得转成 SRAM / register file / single-port or dual-port SRAM；
2. 哪些上下文必须常驻、哪些可以 time-mux；
3. `TQ/TK` 是否存在更优组合，在面积、带宽、周期之间取得更好折中；
4. 是否有 attention accelerator 采用更“窄”的阵列组织，仍保持 baseline 周期在 300k 以内。

### 建议关键词

- `attention accelerator SRAM tiling area tradeoff`
- `FlashAttention ASIC SRAM buffer architecture`
- `attention accelerator local memory hierarchy`
- `tile size attention hardware area bandwidth`
- `systolic attention low area`

### 希望输出

1. 对当前 `q_buf / k_buf / v_buf / row_acc / o_buf` 哪些应该 SRAM 宏化，给出优先级；
2. 给出可能的 `TQ/TK/ROW_PAR/DP_LANES` 调参方向；
3. 判断有没有机会在面积显著下降的同时仍维持 `<300k cycles`。

---

## 7.5 调研任务 D：K/V 带宽复用的更优方案

### 当前痛点

当前 baseline 一次 attention 的主存 traffic 约 **589,824 bytes**，K/V 重读占主导。

### 调研目标

研究是否有适合当前规模和题目约束的 K/V 复用方案：

1. 更大 tile / 多级 tile / streaming reuse；
2. K/V 全量缓存或半缓存的收益与面积代价；
3. 是否有折中的 line buffer / banked SRAM / row-stationary 组织；
4. 如何在不存储 `S×S` 的前提下进一步减少 K/V 外部 traffic。

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
3. 推荐的最现实方案。

---

## 7.6 调研任务 E：是否存在更适合 baseline 的整体微架构

### 当前痛点

当前架构能过周期，但频率和面积都不够稳妥。

### 调研目标

不是只看单个模块，而是查找：

1. baseline `S=256, d=64` 下，业界/学界有没有更适合的 attention microarchitecture；
2. 是否有已经公开的：
   - ASIC attention core
   - FlashAttention-style accelerator
   - streaming softmax hardware
   - low-area transformer attention IP

重点不是追求支持任意大模型，而是**针对固定 baseline 做更好的 PPA 折中**。

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
4. 哪些会破坏当前 baseline 约束，不建议采用。

---

## 7.7 调研任务 F：实现与物理层面的收敛技巧

### 当前痛点

即使架构改好，最后仍要落到 55nm 工艺的综合/STA/P&R。

### 调研目标

查找对这类中等规模算术核常用的物理收敛策略：

1. register retiming / logic restructuring / multi-bit flop / clock gating 的使用经验；
2. 对 RAM-heavy / datapath-heavy attention accelerator 的 floorplan 建议；
3. 是否有对 recurrence-heavy datapath 适用的 CTS / placement 经验。

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

## 7.8 建议给 agent 的统一输出格式

建议要求每个 deep research agent 最终按以下格式输出：

1. **问题定义**：当前项目的具体瓶颈是什么；
2. **外部参考列表**：论文 / 专利 / 开源工程 / 工业博客；
3. **候选方案对比表**：
   - 原理
   - 时序潜力
   - 面积影响
   - 周期影响
   - 误差影响
   - RTL 实施复杂度
4. **最推荐方案**：1~2 个；
5. **落地建议**：如何映射到 `flashattn` 当前 RTL；
6. **风险点**：验证、对齐、误差、接口、存储等。

---

## 7.9 本章结论

如果要把当前项目从“baseline 已可运行、周期已过线”推进到“更像可提交的完整高质量工程版本”，下一阶段最值得调研的方向是：

1. **online softmax recurrence 的新微架构**；
2. **exp / reciprocal / mul 的更适合 500MHz 的实现**；
3. **top 存储层级与 SRAM 宏化**；
4. **K/V 带宽复用**；
5. **更适合 baseline 的整体 attention 微架构**；
6. **后端实现层面的收敛套路**。

建议优先把任务 A、B、C 先交给 deep research agent，因为这三项最直接决定：

- 能否冲击 500MHz；
- 能否控制 top 面积；
- 是否值得继续对当前主线 RTL 做下一轮结构改造。