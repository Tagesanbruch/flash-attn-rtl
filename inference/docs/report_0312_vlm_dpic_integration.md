# SmolVLM2 接入与 FlashAttention RTL DPI-C 协同演进方案

依据 AICAS 2026 VLM 推理赛道题目（`inference/vlm/problem.md`）要求，以及当前 FlashAttention IP 的研制进度（`docs/report_0310/大纲.md`），本文档分析如何将现有的硬件优化成果平滑过渡到 VLM 场景，并详细阐述在 C/C++ 推理端（如 `run.c` 或 `llama.cpp`）通过 Verilator / DPI-C 仿真对接 RTL IP 的具体技术路线。

---

## 1. VLM 赛题要求与现有 IP 的匹配度分析

AICAS 2026 赛题的核心诉求是在 **KV260 FPGA 平台** 上加速 **SmolVLM2-500M-Video-Instruct**，评估指标为 **OCRBench 的准确率（允许最多下降 5%）** 和 **Prefill/Decoding 吞吐量提升率**。

### 1.1 现状与挑战
1. **序列长度 (Sequence Length) 挑战**：
   - **现有 IP**：严格面向单 block $S=256$, $D=64$ 设计，且不保存中间注意力量级矩阵，天然利用 `Q8.8` 定点化换取性能。
   - **VLM 场景**：考虑到 SmolVLM2 会对图像/视频进行 Token 展开，进入 LLM 后端的 Prefill 序列常常长达几千个 token（远超 256）。如果仅仅是 Decode 阶段，单步递增还可以，但在 Prefill 阶段面临超大 $S$ 的计算压力。

2. **硬件/软件分工转换（Block Merge）**：
   - 现阶段 IP 仅输出归一化好的 $O$。为了满足长序列需求，推断引擎必须在软件端对序列进行分块（$S_{chunk} = 256$）。
   - 要合并多个独立计算的 $256 \times 256$ 块输出，RTL IP 必须能向外引出（或写回内存）每个 Chunk 的最后得分最大值 $m$ 以及分母累加量 $l$。只有这样，软件侧（或下一轮硬件侧）才能完成无损的长下文 FlashAttention Block Merge。

3. **精度（Accuracy）约束**：
   - 赛题允许精度下降控制在 $-5\%$。从目前的测试看，Q8.8 FP32 的完全一致性不高，但逻辑上依然合理。VLM 特别是 OCR 任务，对于坐标和细文本的恢复对精度敏感，可能需要评估 Q16.16 或做异常点（Outliers）的特殊浮点旁路处理以严守 $Acc_{ori} - 5\%$ 门限。

### 1.2 引入 `llama.cpp` 的适配建议
赛题指出使用 `llama.cpp` 作为基线推断工具。
如果不用原生自研 `run.c`，我们在架构设计上需要将硬件算子封装封装成可以注册进 `ggml` 计算图的 custom backend（如 `ggml-fpga.c`），这样 `llama.cpp` 解析到 `OP_ATTN` 时会进行硬件派遣。

---

## 2. DPI-C / Verilator 软硬件协同集成方案 (Infer 端接入)

为了在板卡实际流片/烧录前验证 SmolVLM2 能否在我们的结构上跑通，我们必须通过 DPI-C 把现有的 `fa_attention_ip_top.sv` 挂载到软件推理引擎（`run.c` 或 `llama.cpp`）内部。

### 2.1 整体架构设计

在 `run.c` 视角的修改非常干脆——**使用软件分配的一段内存（由 Verilated 模型和 C++ 程序共享），并暴露 AXI-Lite API 给 C/C++。**

```text
┌────────────────────────────┐
│  VLM 推理引擎 (run.c/CPP)  │
│ 1. 识别到 Attention 算子   │
│ 2. FP32 -> Q8.8 量化       │
│ 3. 内存准备 (Q, K, V)      │
│ 4. fa_hardware_forward() ──┼─────┐
│ 5. Q8.8 -> FP32 反量化     │     │ DPI-C Bindings
└────────────────────────────┘     │
                                   ▼
                            ┌─────────────────────────────────┐
                            │ Verilator C++ Wrapper           │
                            │ (fa_attention_ip_top)           │
                            │ 1. 模拟 AXI-Lite 写入 Config    │
                            │ 2. AXI-Master DMA 桥接到宿主内存│
                            │ 3. verilator_eval() 步进仿真    │
                            └─────────────────────────────────┘
```

### 2.2 Infer (推理侧) 需要做的具体代码修改

1. **共享内存申请 (Host RAM 模拟)**
   IP 的 AXI DMA master 会发送 32 位地址来读写内存。推断前，我们要分配一个巨大的 C-array，并将此数组的首地址指针告诉 Verilator 模型。
   ```c
   // 推理端：
   uint8_t sim_ddr[256 * 1024 * 1024]; 
   ```

2. **实现 FP32/FP16 到 Q8.8 的映射转换**
   在 `run.c` 或 `llama.cpp` 到达 Attention 计算逻辑前，将计算所需的张量（单 Head）从系统的浮点缓存中读取，量化后存入 `sim_ddr` 的指定地址中。
   ```c
   // C 层面完成
   quantize_q8_8(Q_float, sim_ddr + Q_ADDR_OFFSET, S, D);
   quantize_q8_8(K_float, sim_ddr + K_ADDR_OFFSET, S, D);
   ```

3. **创建硬件调度宏函数**
   在 `run.c` 中丢弃或者旁路原来的 `softmax` 和并行运算点积，调用 `fa_hardware_forward`。
   这个函数实质上是通过 DPI-C 暴露出的 AXI 写入操作。

   ```c
   void fa_hardware_forward(uint32_t q_base, uint32_t k_base, uint32_t v_base, uint32_t o_base) {
       // 通过 Verilator 对 AXI-Lite 写寄存器
       axi_lite_write(0x14, q_base);   // Q_BASE_L
       axi_lite_write(0x1C, k_base);   // K_BASE_L
       ...
       axi_lite_write(0x3C, 32);       // SCALE = 32 (对应 1/8)
       
       // 给启动信号
       axi_lite_write(0x00, 1);        // CTRL = Start
       
       // 等待硬件做完（在仿真中这里就是推进 Verilator 的 时钟 tick）
       uint32_t status = 0;
       while ((status & 0x02) == 0) {  // 读 STATUS 检查 Done-Sticky
           axi_lite_read(0x04, &status);
           sim_tick(); // 此时调用 Verilator tick 函数跑周期
       }
   }
   ```

4. **长上下文切片派发 (Tiling at Host Level)**
   如果在 SmolVLM2 的 Prefill 阶段遇到 $S = 1000$，按照当前 RTL 设计（只吃 $S=256$），`run.c` 的 Attention 函数不能只是调用一次，而是要构建外层软件循环：
   - 拆分为 4 个长 $256$ 块，分别派发给 IP 计算。
   - **前提要求**：RTL 在设计上必须为软件开一个通道（比如 AXI DMA 增加 `Context_Save_Base_Addr`），在结算出一个 `Block O` 的同时也向 DDR 写回局部的 $l$ 和 $m$ 数组；或者软件侧读出 O 后根据原始结果重新逼近（后者难度过大）。
   - 软件对 4 个块的局部 O、局部 $l$、$m$ 按照 FlashAttention 的全局合并公式合并为全局 $O_{final}$。

---

## 3. 下一步研发行动指南

若要全力冲刺 AICAS 2026：

1. **SmolVLM2 架构微观摸底**
   - 立即编写 Python 脚本加载 `SmolVLM2-500M-Video-Instruct`，抓取其真实的隐层维度 $D$ 是 64 还是 128 / 256？
   - 如果 $D \neq 64$，立刻对 RTL 的 `QK dotprod`、`fa_o_normalize_block` 参数实例化做适配放大，或者向赛方确认是否允许做特征维度裁剪。

2. **打通 `run.c` <- DPI-C -> `fa_attention_ip_top.sv` 仿真环境**
   - 不再只满足于使用 Python 投喂数据，而是直接在 `run_fa.c` 推理 C 源码内引入 `<verilated.h>`，把真正的 LLM Token 特征压入 DMA 读取段，并接管 AXI 读写。

3. **增加 Block-Merge (长序列) 附加特性**
   - 重点检查预留给 AXI 的写出通道。如果目前写出仅仅写出 Q8.8 的 $O$。
   - 需要在 RTL 核心的 `S_NORMALIZE` / `S_WRITE_O` 态增加对当前 Query Row 所锁定的 `m` 和 `l` 状态进行突发传输出系统 DDR 的设计，为超过 256 长图文 token 的拼接打好基础。
