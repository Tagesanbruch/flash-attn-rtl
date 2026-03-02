# 基于 FlashAttention 的端侧定点注意力 IP：研究综述与架构建议

## 一、执行摘要

目标是在**≤200 万门**（约 15–20 mm²@16nm 量级）、**极少片上 SRAM（仅容纳小 K/V tile）**的 SoC 上，实现一个基于 FlashAttention 思想的注意力 IP，数据格式为**Q8.8 16 bit 有符号定点**，内部累加 ≥32 bit，**禁止存完整 S×S 注意力矩阵**。

调研结果表明：

- **算法层面**：FlashAttention 本质是把 Milakov Online Softmax 的在线归一化思想，扩展到 tiled attention，使得仅需 O(S·d) 级别的缓存即可完成精确 softmax 注意力。V2/V3 进一步在**乱序调度**、**异步执行**和**低精度（FP8）**上优化。
- **硬件层面**：SystolicAttention (FSA)、FlatAttention、SpAtten 分别代表三类设计范式：**单阵列全融合**、**多 Tile+NoC 协同**、**稀疏剪枝+量化**。其中 FSA 的思路（在线 rowmax/rowsum + 阵列内 PWL-exp）最适合缩减为小规模端侧 IP。
- **定点与非线性单元**：指数与倒数可以通过**分段线性插值（PWL）+ 小表**、**短程 Taylor 展开**或**迭代法（Newton/Goldschmidt）**实现，以 <1–2% 精度损失换取 >30–50% 面积/能耗节省。
- **PPA 对比**：FSA 在 16nm、1.5 GHz 下仅增加 ~12% 面积即可获得 1.77×/4.83× 的阵列利用率提升；SpAtten 在 18.71 mm²、8.3 W 下实现 1.61 TFLOPS (BERT)；FlatAttention 在 tile-based 架构上实现 89.3% 利用率和 HBM 16× 流量削减。

综合考虑你的**门数/SRAM约束**与**定点 Q8.8 要求**，建议采用：

> **“缩小版 SystolicAttention” + Q8.8 定点化：64×64 阵列 + K/V 双缓冲 tile + 阵列内 PWL 指数 + 迭代倒数 + Online Softmax 状态寄存器**。

下文按要求分五个维度详细展开，并给出**针对你芯片约束的具体微架构方案**。

---

## 二、基础理论与算法演进

### 2.1 Online Softmax 数学原理与硬件含义

Milakov & Gimelshein 提出的 **Online normalizer calculation for softmax**[1] 针对一行 softmax：

\[
y_i = \frac{e^{x_i}}{\sum_j e^{x_j}}
\]

维护两类在线状态：

- 行最大值 \(m\)：  
  \[
  m^{(t)} = \max(m^{(t-1)}, x_t)
  \]
- 指数和 \(l\)：  
  \[
  l^{(t)} = l^{(t-1)} \cdot e^{m^{(t-1)} - m^{(t)}} + e^{x_t - m^{(t)}}
  \]

只需遍历一次就能获得稳定的 softmax 归一化常数 \(l^{(n)}\)，无需保存整行的 \(e^{x_i}\)。  
**硬件视角：**

- m 和 l 可在每个 row 上用两个寄存器维护；
- 对每个新 x，仅需：
  - 1 次最大比较
  - 2 次指数运算
  - 2 次乘加运算
- 内存占用从 O(S) 浮点数组降为 O(1) 状态。

FlashAttention 的“在线 softmax”正是将这个逻辑扩展到**Block/Tiling** 场景。

### 2.2 FlashAttention V1：IO-aware Tiled Exact Attention

FlashAttention V1 的核心思想：

1. 将 Q/K/V 按 sequence 维度切成大小为 \(B_r, B_c\) 的 tile：
   - Q tile：\(B_r \times d\)
   - K/V tile：\(B_c \times d\)
2. 对每对 (Q_tile, K_tile) 计算局部得分：  
   \[
   S_{block} = Q_{tile} K_{tile}^T
   \]
   然后用 Online Softmax 维护整行的全局 m/l：
   - 每处理一个 K_tile 就更新一次 m/l。
3. 最后结合 V_tile 计算：
   \[
   O = \sum_{blocks} P_{block} V_{tile}
   \]

**关键点**：从**“materialize S×S”** 变为 **“按 tile 依次算+累加”**，所有 softmax 状态 m、l、acc 都是**online + per-row 寄存器维护**，仅需缓存当前 tile 的局部 S_block / P_block。

硬件上，只需支持：

- QKᵀ 的 Gemm tile；
- 对 tile 输出进行在线 rowmax、row-sum；
- 与 V tile 的 PV 乘法和累加。

### 2.3 FlashAttention V2：更好的并行与乱序调度

V2 针对 GPU 的瓶颈主要在：

- 部分阶段为**非矩阵运算**（max/sum/exp/div）导致 Tensor Core 利用率降低；
- 某些维度存在 load imbalance。

改进点（抽象为硬件意义）：

1. **增加沿 sequence 维度的并行度**：  
   将不同 Q 区段并行送入多个 warp / SM，相当于你在 ASIC 上可以考虑多行并行处理。
2. **减少非 matmul FLOPs**：  
   合并多个 reduction、重用已算出的中间 m/l，减少显式 Softmax 操作次数。

对你的 IP 启发：

- 若阵列规模有限（如 32×32/64×64），可以通过**多行并行 + 在线复用 m/l** 提高利用率；
- 对于 Q8.8，实现 softmax 时要尽量把非线性/规约**贴近阵列内部**，避免独立矢量单元造成瓶颈。

### 2.4 FlashAttention V3：异步与低精度

V3 在 Hopper H100 上使用：

1. **异步 Tensor Core (WGMMA)** 与 **TMA** 让：
   - GEMM 计算与数据搬运、Softmax 规约**两级流水叠加**；
2. **FP8 Block Quantization + Incoherent processing**：
   - 对 Q/K/V 等 block 做块级 FP8 量化，保持累加 FP16/FP32；
   - FP8 softmax 通过更精细 quantization 策略提高精度。

对你端侧定点 IP 的启示：

- 不一定需要 FP8，但可以仿照其思路：
  - **存储/带宽用更低精度（Q8.8）**，内部关键累加使用 32-bit；
  - 用**块级缩放因子**消化动态范围。

---

## 三、硬件架构与数据流设计

### 3.1 SystolicAttention (FSA)：单阵列全融合的 FlashAttention

**架构概览**[2]：

- 基准阵列：128×128 2D systolic array，MAC-based（FP16 mul，FP32 acc）。
- 关键扩展：
  - **向上数据通路**：数据可从行底部向顶部传播；
  - **列顶比较器阵列**：执行行方向 rowmax/rowsum；
  - **Split + PWL 单元**：在 PE 中通过分段线性插值实现 exp₂。

**FlashAttention 数据流（单个 N×N tile，N=阵列边长）**：

1. **Q preload（LoadStationary）**：将 Q_tile 固定到阵列寄存器。
2. **QKᵀ 计算 (AttnScore)**：K_tile 从阵列一侧流入，与 Q 形成 S = QKᵀ。
3. **在线 rowmax**：
   - S 的每一行结果沿着 upward path 送至比较器阵列；
   - 比较器维护 old_max/new_max，并输出更新后的 m。
4. **N = S – m 以及累积校正**：
   - m 沿 downward path 返回阵列内部，与 S 一起算 N；
   - 同时更新 Online Softmax 中的 a = old_m – new_m。
5. **指数近似（exp₂）**：
   - 对 N·log₂(e)/√d 使用 8 段 PWL 插值，周期约 8 cycles；
   - 插值系数从阵列边界流入，避免在 PE 内部存储。
6. **rowsum 和 PV**：
   - rowsum：通过把“1”从一侧输入、0 从顶部输入，重用 MAC 阵列做求和；
   - 同时/之后进行 P·V 的矩阵乘法，输出 O_tile。
7. **重缩放（AttnLSENorm）**：
   - 用保存在 Accum SRAM 中的 log-sum 计算倒数，对 O 进行最终归一化。

**时序**：

- 一个 N×N tile 的 FlashAttention 内核耗时：**5N + 10 cycles**；
- 对比朴素方案（两次 Gemm + 分离 Softmax）：约 **8N – 2 cycles**；
- 重缩放步骤额外 2N+20 cycles，但相对内核可忽略。

**关键特性**：

- 所有非矩阵操作（max/sum/exp）**都在阵列内用“矩阵数据流+少量附加逻辑”实现**；
- 不需要单独的 vector/scalar 单元，**非常适合你的“少逻辑门 + 少 SRAM”要求**。

### 3.2 FlatAttention：Tile-based 多核 + NoC 集体通信

**架构概要**[3]：

- 32×32 Tile mesh，总 1024 Tiles；
- 每 Tile：
  - Matrix Engine (RedMulE)：32×16 MAC array（1 TFLOP/s FP16）；
  - Vector Engine (Spatz)：16 FPUs（128 GFLOP/s）；
  - 本地 L1：384 KB，512 GB/s；
- NoC：2D mesh，1024-bit 链路，支持 multicast、sum-reduction、max-reduction 等硬件 Collectives。

**数据流**：

1. Tiles 分组成 Gx×Gy 的 group（常用 32×32，全阵列）；
2. Q 由西侧 Tiles 从 HBM 读入，组内**行向 multicast**；
3. Kᵀ/V 由南侧 Tiles 读入，**列向 multicast**；
4. 各 Tile 在其本地 slice 上计算局部 S_block, P_block, O_block；
5. 通过 NoC Collectives 在 group 内完成 rowmax/rowsum 的**全局归约**与 broadcast；
6. 异步版本 FlatAsyn：同一个 group 并行计算两头，重叠 Softmax/数据搬运与矩阵运算。

**特点**：

- 极大地利用 on-chip 总存（384 KB×1024）作为逻辑统一的“大 SRAM”；
- 通过 multicast 减少 HBM 访问（可达 FlashAttention‑3 的 1/16）。

对你的情形：

- 这类“多 Tile + NoC”结构对你 2M 门的 SoC 显然过重；
- 但值得借鉴其思想：**用小 SRAM tile + 组内广播/规约**替代单大阵列。

### 3.3 SpAtten：稀疏注意力架构

**架构特征**[4]：

- 目标：利用 token sparsity、head sparsity 与量化机会加速注意力；
- 关键单元：
  - **Cascade token pruning**：跨层累积 token 重要度，剪掉低重要 token；
  - **Cascade head pruning**：对整头剪枝；
  - **Top‑k 排序引擎**：16 比较器/阵列，quick-select 风格，O(n) 平均复杂度；
  - **渐进式量化**：先用 MSB 低比特计算，如果 softmax 分布过“平”（不够确定）再取 LSB 重新计算。

**数据流简化描述**：

1. 执行粗精度注意力以获得 token/head 重要度；
2. 通过 Top‑k 引擎选择需要保留的 token/head；
3. 对保留部分以较高精度/较深 pipeline 执行完整 QKᵀ+Softmax+PV；
4. 对剪枝得到的稀疏结构再做 FFN 等下游运算。

**适用性评估**：

- 非常适合在**稀疏度高且不严格追求精确注意力**时节约算力/带宽；
- 但需要大量的 top‑k/控制逻辑；在 2M 门预算下，作为**第一版** IP 不建议直接采用（可以将稀疏剪枝作为后期版本）。

---

## 四、存储层级与缓存管理

### 4.1 K/V Tile 缓存与双缓冲

你只能容纳少量 K/V tile，因此需要：

1. **双缓冲 K/V SRAM**：
   - Buffer A：供当前 Q_tile × K_tile、P_tile × V_tile 计算；
   - Buffer B：从外存预取下一 tile；
   - tile 计算与数据搬运可重叠，隐藏读取 latency。

2. **Ping‑pong 结构**：
   - 读写地址空间对称：当 A 变为“写入下一块”的 buffer 时，B 则提供当前计算；
   - 控制逻辑简单，只需一位状态标识当前 active buffer。

FSA 中的 STile（Scratchpad）与 ATile（Accumulation）即内嵌类似思想：每次 compute 指令只读 1 tile、自上而下流水处理、写 1 tile 到 Acc SRAM，使数据流确定化。

### 4.2 m/l/acc 的寄存器管理

在线 softmax 对每一行需要：

- m：max（建议 Q8.8 或更高定点）；
- l：指数和（可用 Q8.24 等更宽格式）；
- acc：输出累加器（32 bit 或更高）。

在 systolic 阵列架构下：

- 每个 PE 对应输出矩阵 O 的一个元素；  
  可用 PE 内部寄存器维护对应行的 m/l 状态：
  - 行向流水时，将某行的 m/l 在一条“状态通道”上传递；
  - 对应行的新 S_block 到来时，用当前 m/l 更新；
- acc 由阵列外的 Accum SRAM（如 FSA 中 2 MB）与 PE 存储组合维护：  
  - PE 内部做 tile 级累加；  
  - tile 结束时写回 Accum SRAM。

你的情况（64×64 或更小阵列）下，可压缩：

- m/l 在每行一个“row context register file”中维护，如 64 行 × (m: 16bit + l: 24–32bit) ≈ 几 KB；
- acc 可以边算边写回到一个小型 Accum SRAM（如 128–256 KB）。

### 4.3 SRAM 面积 vs 外部带宽 Trade‑off

- 较大的 SRAM 可以缓存更多 K/V tile，从而减少外存访问，但**你受面积/门数严格限制**；
- 折中策略：
  - 用 **128–256 KB SRAM** 作为 K/V 双缓冲；
  - Q 和中间 m/l/acc 尽量**驻扎在寄存器/小 RF**；
  - 通过**序列分块**（例如 S=256，分成 4 个 64 长度 block）限制一次处理行数，避免大 S×d 占用。

---

## 五、定点 Q8.8 与非线性单元设计

### 5.1 Q8.8 约束下的数值范围规划

- Q/K/V 通常经过 LayerNorm/缩放，元素范围约落在 [-8, 8] 或更小；
- Q8.8：
  - 整数部分 8 bit（含符号），覆盖 [-128, 127.996]，完全够用；
  - 小数部分 8 bit，步长 ≈ 0.0039。

建议：

- 内部乘加使用 **16×16→32bit 累加**；
- 在 softmax 前做简单 clamping（如 [-10, 10]）以减小指数动态范围。

### 5.2 指数函数的近似实现

#### 5.2.1 PWL（分段线性插值）方案

借鉴 FSA 中的方案和 Softmax 近似评估工作[5]：

- 对 \(x\) 先缩放为 \(z = x·log₂(e)/√d\)，使 z∈[-1,0] 或更窄区间；
- 划分为 8 段均匀区间，每段有线性函数：
  \[
  e^x ≈ 2^{z} ≈ a_k·z + b_k
  \]
- 将 a_k、b_k 以 Qm.n 定点存 LUT，段索引 k 由 z 的高位确定。

硬件实现：

- 每个 PE 内部只需要：
  - 一次乘法（a_k·z）+ 加法（+b_k）；
  - LUT 存在共享小 SRAM/ROM 中（8 段仅16系数，面积极小）；
- 实测精度（类似设置）：
  - exp₂ PWL 8 段：MAE ≈ 1.4e-4，MRE ≈ 2.7%；
  - 端到端 FlashAttention 的输出差异 MAE ≈ 7e-3–3.4e-2，MRE 1e-2–7e-2；
  - 对 LLM 任务几乎无感知精度下降。

在 Q8.8 下，这个误差水平完全可接受。

#### 5.2.2 LUT + 内插

另一种是“指数 LUT + 线性插值”：

- 例如 64 个样点 + 线性插值，文献给出的：
  - Linear interpolation：RMSE ≈ 3.22e-6；
  - Quadratic：RMSE ≈ 2.31e-7。
- 对资源受限 IP：
  - 更建议使用**少样点 + 一阶线性插值**，LUT 深度可控制在 32–64，宽度 16–20 bit。

PWL 与 LUT 其实非常接近，区别在于：

- PWL 将 LUT 的 x 轴均匀划分，LUT 只存系数（更节省存储）；
- LUT 直接存离散点的函数值 + 简单插值逻辑。

结合门数约束，推荐**PWL 系统**，配以小 LUT 存储 (a_k, b_k)。

#### 5.2.3 低阶 Taylor 展开（可选）

- 对于小区间（如 [-0.5, 0.5]），2–3 阶 Taylor 可达较高精度；
- 评估文献[5]中：
  - 3 阶 Taylor：RMSE ≈ 4.18e-5；
  - 在某些 CNN/LeNet 上仅造成 <0.2% Top-1 准确率损失。
- 缺点：需要 2–3 级乘法，加深时序路径。

在强内核限制下，**PWL 更容易 pipeline 和 meet timing**，因此优先。

### 5.3 除法/倒数运算

在 softmax 中，需要计算：

\[
y_i = \frac{e^{x_i}}{\sum_j e^{x_j}} = e^{x_i}·(1 / l)
\]

建议将“除法”统一实现为“乘以倒数”，即设计**倒数单元**：

#### 5.3.1 牛顿–拉夫逊（推荐）

对于求 \(1/D\)，初始近似 \(y_0\) 可由小 LUT 提供，然后迭代：

\[
y_{k+1} = y_k·(2 - D·y_k)
\]

- 每轮迭代需要 2 次乘法 + 1 次减法；
- 2–3 轮足够得到 20+bit 精度；
- 对单精度定点（Q0.16/Q0.24）：
  - 2 轮常足够（误差 <1e-4）。

硬件层面：

- 牛顿迭代可以利用**阵列中的 MAC** 实现：
  - 将 D, y_k 映射为阵列某列/行，借由乘加网络完成迭代；
  - 或用独立的小乘法器阵列（面积有限）。

#### 5.3.2 Goldschmidt（可选）

Goldschmidt 方法适合 pipeline 化：

1. 初始化：
   \[
   g_0 = 1 - D·c, \quad Q_0 = N·c
   \]
2. 对 k=1..n：
   \[
   Q_{k} = Q_{k-1}·(1+g_{k-1}),\quad g_k = g_{k-1}^2
   \]

- 有利于多乘法并行；
- 文献中实现的 4 轮迭代可得到 <1% 相对误差，延迟 ~100ns。

在你要求**低门数+可重用阵列**的情景，牛顿–拉夫逊更简单。

### 5.4 整体精度评估

采用以下组合：

- Q/K/V：Q8.8；
- 内部乘加：16×16→32 bit 累加；
- exp：8 段 PWL（Qm.n）；
- 倒数：2–3 轮牛顿迭代（Q0.16/Q0.24）。

可预期：

- Softmax 输出的 MAE 在 1e-2 级别，MRE 在 1–3% 量级；
- 对 LLM/GPT 类模型，在已有工作中，这种级别的 softmax 近似通常不会带来明显 perplexity 或 BLEU 损失。

---

## 六、关键硬件工作 PPA 对比（节选）

> 注意：下表中的面积多为论文或推导值，与你芯片的“门数预算”不能直接等价，但可作为相对参考。

| 作品 | 架构类型 | 工艺/频率 | 阵列规模 | 片上存储 | 面积 | 性能/利用率 | 备注 |
|------|----------|-----------|----------|----------|------|-------------|------|
| SystolicAttention / FSA[2] | 单 2D 阵列全融合 FlashAttention | 16nm, 1.5 GHz | 128×128 | Scratch 192 KB, Accum 2 MB | 24.76 mm²；阵列增强+12.07% | FlashAttn FLOPs/s 利用率：1.77× AWS Neuron-v2，4.83× TPUv5e；tile 时延 5N+10 cycles | 阵列两侧增加 upward path+PWL+比较器 |
| FlatAttention / BestArch[3] | 32×32 Tile + NoC Collectives | 5nm (估算), 1 GHz | 每 Tile 32×16 MAC | L1 386 KB/tile，总 >300MB 级 | ~457 mm² | 利用率最高 89.3%；较 FA-3 加速 4.1×；HBM 流量减 16×；对比 H100，利用率 1.3×，带宽降 40% | 偏向大型数据中心加速器 |
| SpAtten[4] | 稀疏注意力专用加速器 | 28nm 级 (文中未给出精确) | 专用 pipeline + Top‑k | Key 196 KB, Value 196 KB + 多 FIFO | 18.71 mm² | 1.61 TFLOPS (22 BERT 模型)；0.43 TFLOPS (8 GPT-2 模型)；DRAM 访问减 10×；对 TITAN Xp 提速 162× | token/head 级联剪枝 + 渐进量化 |
| 各类 Softmax Approx LUT/PWL[5] | Softmax 近似硬件评估 | FPGA | N/A | LUT 若干 | FPGA 资源节省 14–20% | Top-1 精度下降 <0.2–1%（LeNet/MobileNet） | 表明 PWL/Taylor/LUT 近似在定点下可控 |

---

## 七、面向“≤2M 门 + 小 SRAM + Q8.8”的架构建议

### 7.1 总体结构概念

**推荐总体方案**：

> 小规模 systolic-like 阵列（例如 64×64）+ FlashAttention 数据流 + 在线 Softmax + 阵列内 PWL-exp + 牛顿倒数 + K/V 双缓冲 SRAM。

**模块划分**：

1. **64×64 MAC 阵列**
   - 支持 16bit×16bit 乘，32bit 累加；
   - weight-stationary 或 output-stationary 数据流，支持矩阵乘法/规约共用。

2. **Online Softmax 扩展逻辑**
   - 在阵列上方或旁路加入一行比较器 + 加法器，用于 rowmax/rowsum；
   - 在阵列内部增加“状态通道（row context）”以携带 m/l。

3. **PWL 指数单元**
   - 在每个 PE 或每列配置小 PWL 单元：
     - 输入：N·log₂(e)/√d 的定点值；
     - 输出：P ≈ exp(N)；
   - 8 段 PWL，系数存于共享小 ROM (a_k, b_k)。

4. **倒数单元**
   - 小型牛顿–拉夫逊 pipeline：
     - 输入：定点 l（行和）；
     - 输出：1/l；
   - 可视情况串行处理每行，利用阵列空闲槽位。

5. **K/V Tile 缓存 SRAM**
   - 128–256 KB，分为 ping‑pong 两组 buffer；
   - 行为：一组用于当前 tile 计算，另一组预取下一 tile。

6. **acc 存储**
   - 为避免大 SRAM，可轩择：
     - 若单次序列长度不大（S≤256），可直接在阵列中完成所有 Q 对应累加，最终写回外存；
     - 或使用 128 KB 左右的 Accum SRAM 存一层的 O。

7. **控制与调度**
   - 设计小型指令集或固定状态机 FSM：
     - 指令：LOAD_Q, LOAD_KV, MATMUL_QK, ROWMAX, EXP_PWL, ROWSUM, MATMUL_PV, RESCALE 等；
   - 可借鉴 FSA 的“两个 FSM + combiner”模式，一边执行当前指令，一边预取下一指令的控制信号，实现细粒度重叠。

### 7.2 数据流与时序示例（S = 256, d = 64）

假设：

- 阵列 64×64；
- Q_tile = 64×64；K_tile/V_tile = 64×64；
- 整个注意力层被分为 4×4 tiles。

**每个 Q_tile 流程**：

1. LOAD_Q：将 64×64 Q_tile 装入阵列寄存器（若 Q 长度更长，用 row blocking）。
2. 对每 K_tile（总 4 个）：
   - LOAD_K：读入 K_tile 到阵列；
   - MATMUL_QK：得 S_block；
   - ROWMAX+UPDATE(m,l)：阵列内部更新 Online Softmax 状态；
   - EXP_PWL+ROWSUM：得到归一化所需行和增量；
3. 完成所有 K_tile 后，对每个 tile：
   - 使用保存的 Softmax 状态做 RESCALE；
   - 对每 K_tile 重放部分 N/P，执行 MATMUL_PV，产生 O_block，并累加到对应 acc；
4. 最后写回 O_tile。

按照 FSA 的经验，粗略估算：

- 每 tile 复杂度约 = \(\alpha N\) cycles（N = 64，\(\alpha\)≈6–7）；
- 整层总周期 ≈ tiles 数量 × 周期/tilte ≈ (4×4) × (6×64) ≈ 6144 cycles + 开销；
- @500 MHz 时钟，延迟 ≈ 12–15 µs/attention-head，适合端侧速率。

### 7.3 面积与功耗估算（粗略）

以 16nm 为例：

- 64×64 MAC 阵列（16×16→32bit）：规模约 4096 个 MAC；
- 参考 FSA 128×128 阵列 24.76mm²，可估计 64×64 降为约 1/4 面积 ≈ 6–7 mm²；
- 增加 upward path + 比较器 + PWL+倒数逻辑：约 +15–20%；
- K/V SRAM 128–256 KB：约 1–2 mm²；
- 控制/接口逻辑：约 1–2 mm²。

综合估计 IP 面积落在 **10–12 mm²** 内，逻辑门数在 1.5–2M 门区间，有望满足你的目标（具体需工艺库+综合验证）。

---

## 八、小结

1. **算法上**：采用 FlashAttention 的 tiled Online Softmax，实现 O(S·d) 内存需求；Q8.8 定点可在适当 clamping 下保持良好数值稳定性。
2. **架构上**：以 SystolicAttention 为蓝本，构建**小规模 systolic 阵列+在线规约+阵列内 PWL 指数**，去除所有离散 Softmax 向量单元，极大减少逻辑和 SRAM。
3. **存储上**：只为 K/V tiles 配置 128–256 KB 双缓冲 SRAM，其余状态（m/l/acc）尽可能用寄存器/小 RF 保存，acc 通过 tile 粒度 write-back。
4. **定点单元上**：推荐 8 段 PWL 指数 + 2–3 轮牛顿倒数；在已有工作中，这一组合可在 <2% 精度损失下大幅缩减资源。
5. **综合建议**：对于端侧 SoC 的第一代产品，不建议引入复杂稀疏剪枝或多 Tile+NoC；优先实现一个**简化版 FSA**，确保可验证性与实现风险可控，在后续修订中再引入 SpAtten 式稀疏优化和更激进的近似。

如果你愿意，我可以在下一步帮你：  
- 具体推导 64×64 阵列在不同 S,d 下的周期/带宽闭式表达式；  
- 给出一份 RTL 级模块划分与接口定义草案（包括 K/V SRAM 接口与指令格式）。  

---

### 参考文献（按引用顺序）

[1] Online normalizer calculation for softmax. <https://arxiv.org/abs/1805.02867>  
[2] SystolicAttention: Fusing FlashAttention within a Single Systolic Array. <https://arxiv.org/pdf/2507.11331.pdf>  
[3] FlatAttention: Dataflow and Fabric Collectives Co-Optimization for Efficient Multi-Head Attention on Tile-Based Many-PE Accelerators. <https://arxiv.org/pdf/2505.18824.pdf>  
[4] SpAtten: Efficient Sparse Attention Architecture with Cascade Token and Head Pruning. <https://arxiv.org/pdf/2012.09852.pdf>  
[5] A Quantitative Evaluation of Approximate Softmax Functions for Energy-Efficient Deep Neural Networks. <https://arxiv.org/pdf/2501.13379.pdf>