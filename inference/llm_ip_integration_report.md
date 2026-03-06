# 针对 Flash-Attention RTL IP 接入大模型推理的调研与方案可行性报告

本报告旨在评估将当前设计完成的 Flash-Attention RTL IP（SDPA加速器）通过 C/C++ 接口接入如 Qwen3-0.6B 等大模型（LLM）推理代码（如 `run.c` / `runq.c`）中进行端到端仿真与加速比评估的可行性及具体实施方案。

## 一、 IP 规格与 LLM 需求匹配度分析

在将 RTL IP 接入真实 LLM 之前，必须先明确 IP 的硬件规格与目标模型参数之间的结构性差异。

### 1.1 IP 硬件规格 (RTL Baseline)
*   **计算目标**：Scaled Dot-Product Attention (SDPA)
*   **规模限制**：序列长度 **S = 256**，自注意力头维度 **d = 64**，单 Batch 单 Head
*   **计算范式**：基于 FlashAttention-style 的内部 Tiling（TQ=32, TK=64）与 Online Softmax
*   **数据格式**：输入 Q/K/V 和输出 O 均为 **Q8.8 定点格式（16-bit有符号定点数）**
*   **I/O 接口**：AXI4-Lite 用于控制（寄存器配置），AXI4 Master + DMA 用于直接从内存搬运张量数据。

### 1.2 目标大模型规格 (以 Qwen3-0.6B 为例)
*   **注意力头维度 (`head_dim`)**：提取 `config.json` 可知 `head_dim = 128`
*   **序列长度 (`seq_len`)**：实际 LLM 推理上下文长度往往远大于 256（通常4K~32K）
*   **数据格式**：`run.c` 中为 FP32；`runq.c` 中对权重和激活值使用了 **INT8 量化**（结合缩放因子 scale 处理）。
*   **注意力机制**：Grouped Query Attention (GQA)，包含 16 个 Q Head 和 8 个 KV Head。

### 1.3 核心冲突与可行性结论
**在“不修改现存 RTL 代码”的约束下，直接无缝接入 Qwen3-0.6B 是存在结构性数学障碍的，但“接入小型 LLM / Bert 进行端到端走通与仿真验证”是完全可行的。**

#### 冲突点详细剖析：
1.  **Head Dimension 不匹配 (致命问题)**：IP 写死了 `d = 64`，而 Qwen3-0.6B 为 `d = 128`。由于 Softmax 的非线性特性，**无法简单地将 `d=128` 拆分为两个独立的 `d=64` 送入 IP 然后在外部拼接**（因为内部的指数求和分母 $l$ 和最大值 $m$ 是在 IP 内部消化并不输出的）。
    *   *建议*：若不改 RTL，只能用一个配置为 `head_dim=64` 的小模型（例如某些 Bert 的小型变体、TinyLlama修改版，或专门为了验证 IP 而裁剪定型尺寸的模型）来进行端到端效果展示。
2.  **序列长度受限**：IP 限制了全局 `S = 256`。对于大于 256 Token 的输入请求，无法只调用一次。如果要实现全局 Attention，需要软件层面实现 FlashAttention 的 Block 组合逻辑，这要求 IP 输出 Block 级别的 $l$ 和 $m$ 状态。既然 IP 是端到端的整体输出，我们只能**限制评测的输入 Prompt + 生成总长度 $\le 256$**以契合 IP 结构。
3.  **数据格式转换 (Q8.8 vs INT8)**：模型量化算法（GPTQ/AWQ，`runq.c`）跑的是 8-bit Integer (结合外置的 FP32 Scale_factor)，而 IP 需要 16-bit Q8.8。这并不是计算上不可行，而是需要在 CPU 端加一层格式 Pack/Unpack 操作。

---

## 二、 软硬件联合仿真(Co-Simulation)方案设计

抛开上述特定开源模型的维度限制不谈，将该 IP 接入 `runq.c` 的架构方案是非常明确的。为了在 Mac OS 环境下（无真实 FPGA 开发板）走通 CPU 推理 + 硬件 IP 加速的流程，需采用 **Verilator + C++ DPI (Direct Programming Interface) 联合仿真**技术。

### 2.1 联合仿真系统架构

整个系统分为三层：
1.  **应用层 (LLM Inference)**：即经过轻微改造的 `run.c` / `runq.c`。
2.  **驱动与转换层 (C++ Wrapper)**：提供类似于真实驱动的 API（如分配 DMA 内存、数据格式转换、配置寄存器）。
3.  **硬件仿真层 (Verilator Model)**：将 `fa_attention_ip_top` 编译成的 C++ 对象，并在其外层模拟一个伪 AXI 内存总线供 DMA 读写。

### 2.2 关键步骤分解

#### 步骤 1：构建 C++ Verilator 包装器 (Virtual FPGA)
利用 Verilator 将 RTL 编译为 C++ 模型，我们需要用 C++ 写一个 `Virtual_SoC`，其中包含：
*   **主频时钟 (`clk`)** 和不断 tick 的循环。
*   **一块虚拟内存 (`uint8_t* mem_pool`)**：让 LLM 的内存地址映射到这个池子里，这样 AXI DMA 就可以根据 `Q_BASE` 去读取了。
*   **AXI4 行为级模型**：响应 IP 内部发出的 AXI AR/AW/W/R/B 握手信号，将其转变为对 `mem_pool` 数组的读写。

#### 步骤 2：在 `runq.c` 中拦截 Attention 并截获张量
在 `runq.c` 中，原有的 CPU 注意力计算如下（伪代码）：
```c
// 原先在 runq.c 中的 MHA 计算
for (int h = 0; h < p->n_heads; h++) {
    // 算 Q*K
    // Softmax
    // 算 Attention * V
}
```
**修改为 (Proxy 模式)：**
```c
// 1. 数据类型转换与排布 (CPU开销)
// 假设将 Q, K, V 从 LLM 的 FP32 或 INT8 转换为 Q8.8 的一维/二维数组
float_to_q8_8_array(s->q, q_q8_8, S, D);
float_to_q8_8_array(s->k, k_q8_8, S, D);
float_to_q8_8_array(s->v, v_q8_8, S, D);

// 2. 将数据拷贝到 Verilator 可见的"虚拟 DMA 内存区"
memcpy(dma_mem + Q_OFFSET, q_q8_8, bytes);
memcpy(dma_mem + K_OFFSET, k_q8_8, bytes); ...

// 3. 配置寄存器并启动 IP (调用 Verilator C++ 函数)
fpga_write_reg(CFG_REG, causal);
fpga_write_reg(Q_BASE, Q_OFFSET);
...
fpga_write_reg(CTRL_REG, START_PULSE);

// 4. 等待完成并读回结果
wait_fpga_done();
memcpy(o_q8_8, dma_mem + O_OFFSET, bytes);
q8_8_to_float_array(o_q8_8, s->o, S, D); 
```

#### 步骤 3：处理 Q8.8 和 LLM 精度对齐
正如你提到的：“将模型量化到这个IP对应的精度按道理也可以做吧？” 
*   **完全可以。** `run.c` 是算纯 FP32 的，要对接 IP，你不需要重新训练模型，只需要在送入 Accelerator 的前一刻，把当前的 FP32 激活值乘以 256 并强转为 `int16_t` (这就是 Q8.8 表示)；在加速器算完 O 之后，拿回 `int16_t`，除以 256 恢复为浮点数，再接后续的 FFN 网络。
*   在 `runq.c` 中，模型权重已经是 INT8 了，需要根据 Group 量化的 scales 先解量化回浮点数，然后再走 Q8.8 转换；或者将 LLM 的量化方案彻底从 INT8 asymmetric 切换到类似于 IP 内部的 Q8.8。这里建议**早期评测时直接在边界做浮点中转，保证正确性优先**。

---

## 三、 分析与评估指标获取

一旦 `runq.c` 和 Verilator Co-simulation 成功汇合，它不仅能证明该 IP 可以用来跑真实 LLM 生成文本，还能提供关键测评数据：

1.  **端到端精度评估 (Accuracy Check)**：
    *   通过让 LLM (C代码) 生成几段文字。开启 IP 硬件加速与纯 CPU FP32 推理出来的 Logits 分布进行对比（如 Perplexity / MAE）。从而佐证 Q8.8 和硬件近似指数函数（`fa_exp_pwl`）对大模型输出质量是在“可被接受的误差范围内”。
2.  **周期与吞吐估算 (Throughput & Accelerate Ratio)**：
    *   虽然 C++ 软件仿真 Verilator 跑得比真机慢得多，但我们能统计在处理单次 Token 时，**RTL 仿真器走过的“仿真时钟周期数 (`Cycles`)”**。
    *   假设时钟目标是赛题要求的 $1GHz$（$1 ns$/Cycle），我们立刻就能算出硬件跑一次 SDPA 需要多少微秒。
    *   用该“预期硬件耗时”对比 Mac CPU 直接跑 C 代码耗时，即可真正推算出 **相对 CPU 的加速比**。

## 四、 实施总结与建议

综上所述，你的想法**不仅可行，而且是芯片敏捷开发与软硬协同设计（Hardware-Software Co-design）的标准典范动作。**

1.  **模型推荐妥协**：由于 Qwen 系列 `d=128`，建议寻找一个 `d=64` 的小型模型替换测试，例如一些 100M 左右的参数规模极小的实验性 Transformer，或者强行截断 Qwen 的 `head_dim` 只取前 64 维做一次假推理（只为看流水线，虽无语义意义但能跑通数据流）。
2.  **不要强上 `runq.c`**：因为 `runq.c` 处理量化和词表非常复杂。建议先使用**纯浮点版本的 `run.c`** 作为载体。截获它的 MHA 层，将 `float` 转成 `Q8.8 short` 喂给 IP，结果收回转成 `float` 继续，这样改动最小、出错的最少。
3.  **开发路线图**：
    *   *Step A*: 在 `cmodel/` 目录下用 C++ 基于 DPI 写一个能调用 AXI DMA 的完整 Wrapper 类。
    *   *Step B*: 在 `run.c` 中实现软件降级方案（FP32 <-> Q8.8），并用 CModel 模拟调用，观察文本生成是否崩坏。
    *   *Step C*: 用含有 RTL 源码的 Verilator Object 替换掉 CModel 链接库，完成真正的 RTL 级别端到端推理仿真。

---

## 五、 方向一：IP 核改造至 d=128 及更长上下文的工程量分析

### 5.1 当前 RTL 中 D 的参数化程度

通过审查 `fa_attention_core.sv` 全部 731 行代码，**`D` 已经被声明为顶层 parameter**：
```systemverilog
module fa_attention_core #(
  parameter int SEQ_LEN = 256,
  parameter int D       = 64,
  parameter int TQ      = 32,
  parameter int TK      = 64,
  parameter int BUS_W   = 128
) ( ... );
```
所有内部逻辑均通过 `D` 派生 localparam（如 `BEATS_PER_ROW = D / ELEMS_PER_BEAT`、`DP_CHUNKS = D / DP_LANES`），因此**从代码结构上，将 D 改为 128 只需修改实例化参数，不需要重写 FSM 或数据通路逻辑**。

### 5.2 资源占用影响量化分析

当 D 从 64 变为 128 时，以下片上存储资源将受到直接影响：

| 资源名称 | 当前 (D=64) | D=128 后 | 增长比 |
|---|---|---|---|
| **Q Buffer** `q_buf [TQ][D]` (16-bit) | 32×64 = 2,048 个 16b 寄存器 = **4 KB** | 32×128 = 4,096 = **8 KB** | **2×** |
| **K Ping-Pong** `k_buf0/1 [TK][D]` ×2 | 2×(64×64) = 8,192 = **16 KB** | 2×(64×128) = 16,384 = **32 KB** | **2×** |
| **V Ping-Pong** `v_buf0/1 [TK][D]` ×2 | 同上 **16 KB** | 同上 **32 KB** | **2×** |
| **Row Acc** `row_acc [TQ][D]` (64-bit) | 32×64×64b = **16 KB** | 32×128×64b = **32 KB** | **2×** |
| **O Buffer** `o_buf [TQ][D]` (16-bit) | 32×64 = **4 KB** | 32×128 = **8 KB** | **2×** |
| **总片上 Buffer** | **~56 KB** | **~112 KB** | **2×** |

#### 计算单元影响：
-   **Dot Product 单元**：当前 `DP_LANES = 32`，`DP_CHUNKS = D / DP_LANES`。D=64 时 DP_CHUNKS=2（每个 QK dot product 需 2 个时钟周期累加），D=128 时 DP_CHUNKS=4（4 周期）。**乘法器数量不变**，但每次内积计算的延迟翻倍。
-   **Softmax PV 更新**：`C_SOFTMAX_PREP` 中对 `row_acc` 的 D 维度做全展开循环 `for (int k = 0; k < D; k++)`，组合逻辑扇出翻倍。这可能成为**时序关键路径**。
-   **Normalization**：`NORM_LANES = 8`，D=64 时需 8 周期，D=128 时需 16 周期。

#### 延迟影响估算：
-   **单次 Tile 计算周期**：主要由 `TQ × TK × (DP_CHUNKS + 2)` 决定。D=64 时约 `32/2 × 64 × (2+2) = 4096` 周期/tile，D=128 时约 `16 × 64 × (4+2) = 6144` 周期/tile，增长约 **50%**。
-   **面积影响**：片上 Buffer 翻倍（从 ~56KB → ~112KB），需要综合后精确评估是否超出赛题的 200 万门限。在赛题的 ASIC 工艺下，112KB 的 SRAM/寄存器堆可能面积偏大。

#### 结论：**工程量可控（中等偏低）**
由于 D 是参数化的，代码改动量极小（只修改实例化参数值），但需要关注：
1. **面积是否超标**：Buffer 翻倍后综合面积需重新评估
2. **时序是否恶化**：`C_SOFTMAX_PREP` 中 D 维循环展开的组合逻辑链加长
3. **Cycles 增长**：整体执行周期数增长 ~50%，需确认仍在赛题的 <300k cycles 限制内

### 5.3 支持更长上下文（S > 256）：Memory Hierarchy 方案

对于超过 S=256 个 Token 的上下文（如 LLM 推理常见的 2048~32768），在**不改内核**的情况下，可以通过外部软件编排 + 存储层级管理来实现。核心思想源自 FlashAttention 论文本身的 Block-Sparse 外层循环：

#### 5.3.1 外层 Tiling 编排（软件层）
```
对于全局序列 S_total（如 2048）：
  将 Q 切分为 S_total / 256 个 Chunk（每个 256 行）
  对每个 Q_chunk:
    对每个 K/V_chunk（0 ~ S_total / 256）:
      将 Q_chunk, K_chunk, V_chunk 加载到 DMA 可见的内存区域
      配置 IP 寄存器，启动一次 S=256 的 Attention 计算
      获取该 Block 的中间结果 O_partial, m_partial, l_partial
    对当前 Q_chunk 的所有 K/V block 结果做 online-softmax 的 block-merge
```

> **关键问题：当前 IP 只输出最终 O（已做完 normalization），不额外输出 m 和 l 状态。**

这意味着直接把两个 Block 的 O 拼起来是**数学错误的**。正确做法需要 IP 改造：
1. **增加输出端口/寄存器**：将每个 Q-row 的 `row_m` 和 `row_l` 通过寄存器暴露出去（约增加 `TQ × (16+32) = 32 × 48 = 192 字节`的寄存器输出），以便软件层做 block-level rescale。
2. **或增加 "续算" 模式**：增加一个控制位，表示当前 IP 调用是一次 multi-block 中的第 N 个 block，使 IP 不自动做最终 normalization，而是接受外部注入的 m/l 初始值。

#### 5.3.2 Cache 层级设计
在 SoC 集成场景下：
```
┌─────────────────────┐
│   Host CPU / DRAM   │  ← 存放全量 Q[S_total][D], K[S_total][D], V[S_total][D]
│   (GB 级)            │
├─────────────────────┤
│  L2 SRAM / Scratchpad│  ← 存放 1~2 个 S=256 的 Tile（~128KB 级别）
│   (数百 KB)          │     DMA 搬运 tiles 到这里
├─────────────────────┤
│  IP 片内 Buffer      │  ← 当前 q_buf/k_buf/v_buf（~56KB for D=64）
│   (数十 KB)          │     IP 自主通过 AXI DMA 从 L2/DRAM 读取
└─────────────────────┘
```

-   这种 2 级甚至 3 级存储架构中，IP 的 AXI DMA 接口天然兼容。只要 CPU 将对应的 Tile 数据预先搬到 L2/Scratchpad 的某个地址范围内，然后给 IP 配置 `Q_BASE / K_BASE / V_BASE` 指向该区域即可。
-   **预取 (Prefetch)**：IP 内部已经实现了 K/V 的 ping-pong Bank 异步预取。外部可以在 IP 计算当前 Tile 时，用独立 DMA 通道从 DRAM 搬运下一个 Tile 到 L2，实现**双缓冲流水线**。

#### 5.3.3 总结
| 改造项 | 工程量 | 效果 |
|---|---|---|
| D=64 → D=128（只改参数） | **低** | 支持 Qwen3 等 head_dim=128 模型 |
| 暴露 m/l 寄存器用于 Block-merge | **中低** | 支持 S > 256 的外部 multi-block attention |
| 增加"续算模式"控制位 | **中** | 更优雅地支持任意长序列 |
| 外部 Memory Hierarchy + 预取 | **系统集成层面** | 通过 SoC cache/scratchpad 管理数据流 |

---

## 六、 方向二：兼容当前 IP 核（d=64, S≤256）的可用模型

经过搜索和验算，以下主流模型的 `head_dim` 恰好等于 64，可以直接与当前 IP 核对接：

### 6.1 模型列表

| 模型 | 参数量 | hidden_size | num_heads | num_kv_heads | **head_dim** | 类型 | 推荐程度 |
|---|---|---|---|---|---|---|---|
| **Qwen2.5-0.5B** | 0.5B | 896 | 14 | 2 | **64** | Decoder-only (GQA) | ⭐⭐⭐⭐⭐ |
| **Llama-3.2-1B** | 1B | 2048 | 32 | 8 | **64** | Decoder-only (GQA) | ⭐⭐⭐⭐ |
| **TinyLlama-1.1B** | 1.1B | 2048 | 32 | 4 | **64** | Decoder-only (GQA) | ⭐⭐⭐⭐ |
| **GPT-2 (all sizes)** | 117M~1.5B | 768~1600 | 12~25 | MHA | **64** | Decoder-only (MHA) | ⭐⭐⭐ |
| **BERT-base** | 110M | 768 | 12 | MHA | **64** | Encoder-only (MHA) | ⭐⭐⭐ |
| **BERT-large** | 340M | 1024 | 16 | MHA | **64** | Encoder-only (MHA) | ⭐⭐ |

### 6.2 推荐首选方案：Qwen2.5-0.5B

**Qwen2.5-0.5B 是最佳选择**，原因如下：
1.  **head_dim = 64**：与 IP 的 `D=64` 完全匹配。
2.  **`ref/` 目录下已有完整的 C 推理代码**：`run.c` 和 `runq.c` 已经针对 Qwen2.5 系列的词表格式、Chat Template、RoPE 实现做了完整适配。`ref/Makefile` 中的默认模型路径就是 `Qwen2.5-0.5B-Instruct`。
3.  **参数量小**：0.5B 参数，CPU 推理速度可以接受（`run.c` 已验证可在当前 macOS 主机跑通），方便快速迭代。
4.  **seq_len 限制可调**：虽然该模型理论支持 32768，但在 C 代码中可以很容易地限制为 `MAX_SEQ_LEN = 256`，只要输入 Prompt 足够短（如 10~20 个 token），生成的 token 数也控制在 ~200 以内即可。
5.  **量化后的 `runq.c` 也可用**：`ref/runq.c` 已有 INT8 量化版本以及 FlashAttention tile buffer（`fa_s`, `fa_o`, `fa_pv`），提示其原本就有硬件加速意图。

#### 接入可行性：
```
Qwen2.5-0.5B 的每层 Attention：
  14 个 Q heads × head_dim=64  → 每次调用 IP 处理 1 个 head
  2 个 KV heads → GQA，7 个 Q head 共享 1 组 KV
  一层共需调用 IP 14 次（每个 Q head 一次）
  S ≤ 256 时直接匹配 IP 规格
```

### 6.3 次选方案：GPT-2 / BERT

若希望选择更简单的模型降低调试难度：
-   **GPT-2 (124M)**：经典 Decoder-only，head_dim=64，结构最简单。缺点是不支持 GQA，没有 RoPE（使用 learned position embedding），需要单独写 C 推理代码或使用社区的 `gpt2.c`。
-   **BERT-base**：head_dim=64，Encoder-only 模型。适合做分类/填空等非生成任务的仿真验证。缺点是 BERT 的 Attention 是 **Bi-directional**（非 causal），IP 的 causal mask 需要设为关闭（`CAUSAL_EN = 0`）。

### 6.4 关于 Qwen3-0.6B 的处理

已确认 Qwen3-0.6B 的 `head_dim = 128`，与当前 IP 不兼容。要支持它必须走"方向一"的 D=128 改造路线。如果改造完成，Qwen3-0.6B 也是很好的目标（参数量小、有完整 HuggingFace 权重）。
