# FSA（2507.11331v4）论文与开源工程全栈分析（对比赛题要求）

## 1. 结论先行

- **能否作为参考？** 可以，而且价值很高。FSA 在“将 FlashAttention 的非矩阵操作（rowmax/exp/sum/reciprocal）融合进单个 systolic array”方面是当前非常强的**微架构参考**。
- **能否直接作为你当前赛题的 IP 提交基线？** 不合适直接复用。原因是它的默认实现与赛题 baseline 在**数据格式、接口形态、验证口径**上存在关键不一致。
- **是否能满足题目目标？** 经过“定点化 + 接口重构 + 验证重建”后，**可作为核心计算内核思路**，但不应直接当成最终 IP。
- **作为计划中的定位建议**：把 FSA 定位为“中层/底层微架构和调度方法参考”，而不是“可直接接线的 Top 级 IP”。

---

## 2. 工程全景：从软件到硬件

本分析基于 `ref/FSA` 代码树（Chisel generator + Python API + Verilator/FPGA运行路径）。

### 2.1 软件栈（顶层）

- Python 侧提供 DSL + kernel 描述：`python/main.py`。
- 关键 kernel 是 `scaled_dot_product_attention`，通过：
  - `alloc_spad/alloc_accumulator`
  - `mx_load_stationary / mx_attn_score / mx_attn_value / mx_reciprocal / mx_attn_lse_norm`
  - `load_tile / store_tile / fence`
  生成指令流并驱动仿真或 FPGA。
- 参考模型：`python/fa_ref.py`（PyEasyFloat）实现 tile 级在线 softmax 更新，用于数值比对。
- 仿真引擎：`python/fsa/engine.py` 的 `VerilatorSimulator`，通过 `+loadmem/+dump-mem` 驱动 chipyard 生成的仿真二进制。

**要点**：软件模型是“指令驱动矩阵引擎”，不是直接 AXI-Lite 启停寄存器模式。

### 2.2 ISA 与前端解码

- 指令分三类：`MATRIX` / `DMA` / `FENCE`（见 `src/main/scala/fsa/isa/ISA.scala`）。
- `MatrixInstruction` 与 `DMAInstruction` 都包含 semaphore acquire/release 字段，支持跨引擎依赖同步。
- `Decoder.scala` 把 32-bit beat 合并成 96/128-bit 指令，再分别送到 matrix/dma 路径。

**要点**：FSA 是“**queue 指令机** + semaphore 协同”，而非比赛要求的“固定寄存器配置 + start/done 控制面”。

### 2.3 控制面与执行计划生成（核心亮点）

- `ExecutionPlan.scala` 把每条矩阵指令抽象为时间表：
  - spad/acc 读时序
  - comparator 命令
  - accumulator 命令
  - PE 控制波形
  - semaphore release / conflict-free 时刻
- `ControlGen.scala` 自动压缩控制波形（parallel/up/down flow）并生成每行 PE ctrl。
- `MatrixEngineController.scala` 使用双 FSM（可重叠）调度矩阵流水，支持 read/compute/accumulate 局部重叠。

**要点**：FSA 的“执行计划描述 + 自动控制生成”非常适合作为你后续中层控制器设计参考。

### 2.4 计算阵列与算术单元（底层）

- `SystolicArray.scala`：2D PE 阵列 + 顶部 comparator 链路 + 上下双向流。
- `PE.scala`：单 PE 支持 MAC、寄存器装载、exp2 等模式切换。
- `CMP.scala`：支持 UPDATE/PROP_MAX/PROP_MAX_DIFF/PROP_EXP2_INTERCEPTS 等软最大值流程命令。
- `Accumulator.scala`：支持 `EXP_S1/EXP_S2/ACC_SA/ACC/RECIPROCAL`，用于在线 softmax 的 l 和输出归一化。
- `FPArithmeticImpl.scala`：
  - 默认是 FP 系（如 fp16 mul + fp32 acc）
  - `exp2` 用 PWL 斜率/截距
  - reciprocal 用除法器多周期实现

**要点**：论文提出的“非 matmul 操作也在阵列内完成”在代码里是实实在在落地的。

### 2.5 存储层级与 DMA

- `BankedSRAM.scala`：spad/acc 为 banked SRAM，支持 full-row 与 narrow 访问。
- `DMA.scala`：多端口 AXI4 master + load/store queue + request partition，面向高并发搬运。
- `AXI4FSA.scala`：
  - 通过 AXI4RegisterNode 提供配置区（写入 raw instruction queue、激活执行、读性能计数）
  - 连接 DMA memory node。

**要点**：FSA 已有完整 memory hierarchy + DMA 体系，适合借鉴你的“低中间存储 + KV tile 流水搬运”目标。

---

## 3. 与赛题要求逐项对比

## 3.1 对齐项（可直接借鉴）

1. **FlashAttention-style 关键约束**
   - 不显式存完整 S×S：对齐。
   - 在线 softmax：对齐。
   - tiling：对齐。

2. **memory hierarchy 与带宽优化**
   - 具备 spad/acc + DMA + 指令级重叠：对齐。

3. **硬件融合思路**
   - 将 max/exp/sum/norm 融入阵列数据流：强对齐（高价值参考）。

## 3.2 不对齐项（必须改造）

1. **数据格式**（赛题强制 Q8.8）
   - FSA 默认 FP16/FP32，不是定点 Q8.8。
   - 这是最大差距之一。

2. **接口规范**（赛题要求固定 AXI4-Lite 寄存器 + DMA）
   - FSA 控制面是“写 raw instruction FIFO + activate + perf counters”。
   - 与题目给定寄存器表（CTRL/STATUS/CFG/Q_BASE...）不一致。

3. **功能项：causal mask**
   - FSA 当前工程和 python kernel中看不到 causal mask 功能路径（至少无显式接口/控制项）。
   - 赛题 baseline 要求 causal 必须支持。

4. **验证口径**
   - FSA 验证偏向 FP 与 torch 对齐；
   - 赛题要定点误差门限（mean/max abs）与指定 corner case（如 i=0 仅看 j=0）。

5. **交付形态**
   - FSA 为 chipyard 生态生成器，不是独立 SV IP 交付包。

## 3.3 面积与目标匹配讨论

- 你提到论文中“扩展核 area ~2M μm² 量级（约 2 mm²）”这一点，说明**微结构本身具备较好面积效率**。
- 但赛题门数统计口径（含存储折算）与具体工艺库、定点实现关系更直接，不能直接拿 FSA 论文面积数值等价替换。
- 结论：面积上“有希望”，但必须在你目标格式/工艺/综合脚本下重新评估。

---

## 4. 是否适合纳入你的开发计划？

## 4.1 适合纳入（建议）

把 FSA 纳入计划中的以下层级：

- **中层架构参考**：ExecutionPlan + 控制生成 + 双 FSM overlap。
- **底层数据流参考**：PE/CMP/Accumulator 的操作融合方式。
- **memory/dma 参考**：banked SRAM + load/store queue 分工。

## 4.2 不建议照搬（需替换）

- 不建议把 `AXI4FSA` 指令队列控制面原封不动用于比赛提交。
- 不建议继续 FP16/FP32 作为 baseline 数据通路。
- 不建议依赖 chipyard 才能跑验证。

---

## 5. 从 FSA 到赛题 SV IP 的迁移路线（建议）

## 5.1 迁移原则

- 保留“算法/微结构思想”，替换“接口、数据格式、工程依赖”。

## 5.2 分层迁移（从易到难）

### 层 A：先提炼纯计算内核（无总线）

- 目标模块：`row/tile compute core`（SV）。
- 输入输出：流式 score/value 或 Q/K/V tile 接口。
- 功能：online softmax + causal + norm。
- 验证：cocotb 单模块/中层回归。

### 层 B：替换为赛题控制面

- 实现 AXI4-Lite 固定寄存器 map（题目给定）。
- 保留 DMA master，但改为以 base/stride 驱动，不再依赖指令流 ISA。

### 层 C：完善定点数据通路

- 将 FPArithmeticImpl 思想改写为 Q8.8 + 高位累加。
- exp/reciprocal 用近似模块（你当前已建 `fa_exp_pwl_*`/`fa_recip_*` 原型）。

### 层 D：中层/顶层验证与 STA

- 中层 verif + syn（本机可做）。
- 顶层 syn 等服务器就绪后推进。

---

## 6. “能否 SV 化”评估

## 6.1 可行，但分两条路线

### 路线 1：先 Chisel 出 SV，再收敛

- 直接用 CIRCT 导出 SV（仓库已有 `utils/SVGen.scala` 示例，已对 SA 子模块可用）。
- 优点：快拿到结构；
- 风险：
  - 生成代码可读性与可维护性一般；
  - 仍可能带 chipyard/cde 类型耦合（尤其顶层）。

### 路线 2：按 FSA 思想手写 SV

- 按你当前工程风格（`rtl/common|softmax|core`）逐层实现；
- 优点：更贴赛题接口、定点格式、DV路径；
- 风险：开发周期更长。

**建议**：采用“1+2 混合”：
- 先对 `SystolicArray/PE/CMP` 做导出参考；
- 最终交付模块仍手写 SV（尤其 top/control/dma/寄存器面）。

---

## 7. 无 chipyard 环境下的仿真方案

## 7.1 可行性结论

- **完全可行**。你不需要 chipyard 才能推进当前目标（单点 attn 推理与验证）。

## 7.2 推荐路径

1. **纯 SV + cocotb + Verilator**（你当前路径）
   - 把 FSA 思想映射成独立模块；
   - 用 Python golden 对比；
   - 用 Makefile 统一回归。

2. **若需要复用 FSA Python kernel 语义**
   - 复刻其 tile 调度逻辑到你的 python driver；
   - 不依赖 FSA 的 chipyard 指令装载流程。

3. **可选中间态**
   - 对个别 Chisel 子模块（如 SA）导出 SV，接入你自己的 testbench。

---

## 8. 对你当前计划的具体建议（可执行）

1. 在你现有 `plan.md` 中新增“FSA 参考映射”章节：
   - ExecutionPlan → 你的 `tile/row controller`
   - CMP+Accumulator 命令流 → 你的 softmax pipeline 状态机
   - BankedSRAM + DMA queue → 你的中层 memory hierarchy

2. 明确“不可继承项”清单：
   - FPArithmeticImpl；
   - 指令队列控制面；
   - chipyard 绑定路径。

3. 先做一个“FSA-style but contest-compatible”中层核：
   - 输入 Q/K/V tile；
   - 输出 O tile；
   - Q8.8；
   - causal on/off。

4. 用你现有 cocotb 架构扩成中层 DV：
   - 先 S=32,d=64 缩尺验证；
   - 再扩到 S=256。

---

## 9. 最终判断

- **作为参考：强烈推荐。**
- **作为直接 IP：不推荐。**
- **作为迁移起点：推荐“微结构借鉴 + 工程重构”路线。**
- 若目标是“本机快速达成单点 attn 推理+verif，再走 yosys/iEDA STA”，FSA 的价值在于：
  - 让你少走微架构弯路；
  - 但不应该绑死在 chipyard/chisel 生态。
