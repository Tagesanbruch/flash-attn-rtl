# 2026-03-09 FlashAttention RTL 理论分析与架构拆解报告

## 1. 目的与范围

本文针对当前主线 RTL，系统整理以下内容：

1. 当前 `fa_attention_core` / `fa_attention_ip_top` 的实际架构与数据流
2. 理论计算延迟、DMA/访存延迟、带宽、算力分析
3. 关键参数（`TQ/TK/ROW_PAR/DP_LANES/NORM_LANES/BUS_W` 等）对性能的影响
4. 当前 RTL 的结构性指标：tile 组织、片上存储体系、DMA 参数、主/子状态周期构成
5. `fa_attention_core` 内部巨量组合运算的来源与 PPA 风险
6. 在**不修改代码**前提下，对后续可拆解方向和流水化可能性的理论判断

除特别说明外，本文以当前 RTL 默认参数、并以 $500\text{MHz}$ 作为统一评价频率进行估算。

---

## 2. 当前 RTL 架构总览

### 2.1 顶层分层

当前顶层由 [rtl/top/fa_attention_ip_top.sv](rtl/top/fa_attention_ip_top.sv) 组织，主要包括：

- `fa_axi_lite_regs`：控制/配置/状态/性能计数器寄存器
- `fa_dma_reader`：AXI4 Master 读 DMA
- `fa_dma_writer`：AXI4 Master 写 DMA
- `fa_attention_core`：主计算核心
- `fa_perf_counters`：本轮新增的旁路性能计数器

从结构职责看，`fa_attention_core` 自身同时承担：

- Q/K/V/O tile 的调度与 DMA 发起
- tile buffer 的装载与 ping-pong prefetch 控制
- online softmax 的状态维护
- 点积、score 缩放、softmax 更新、PV 累加
- normalization 与写回

因此当前 `fa_attention_core` 是一个**高度集成的单体式 datapath + scheduler**。

### 2.2 默认参数

从 [rtl/core/fa_attention_core.sv](rtl/core/fa_attention_core.sv) 可读到：

- `SEQ_LEN = 256`
- `D = 64`
- `TQ = 32`
- `TK = 64`
- `BUS_W = 128`
- `ROW_PAR = 2`
- `DP_LANES = 32`
- `DP_CHUNKS = D / DP_LANES = 2`
- `NORM_LANES = 8`

由此得到：

- `NUM_Q_TILES = 256 / 32 = 8`
- `NUM_K_TILES = 256 / 64 = 4`
- `ELEMS_PER_BEAT = 128 / 16 = 8`
- `BEATS_PER_ROW = 64 / 8 = 8`
- `BEATS_PER_TILE_Q = 32 * 8 = 256`
- `BEATS_PER_TILE_KV = 64 * 8 = 512`

---

## 3. 数据流与执行流程

### 3.1 外层主状态机 (`ms`)

主状态机顺序为：

1. `S_LOAD_Q`
2. `S_INIT_CONTEXT`
3. `S_LOAD_K`
4. `S_LOAD_V`
5. `S_COMPUTE`
6. `S_NORMALIZE`
7. `S_WRITE_O`
8. `S_NEXT_Q`
9. `S_DONE`

每个 `Q tile`（32 行）重复一次上述流程。

### 3.2 内层计算子状态机 (`cs`)

在 `S_COMPUTE` 内部，子状态机为：

1. `C_DP_RUN`
2. `C_SCORE_DONE`
3. `C_SOFTMAX_PREP`
4. `C_DONE`

但它不是“65536 -> 32768 -> 32768 三大块一次性串完”，而是：

- 针对**每一个 score-pair**，执行一次
  - `2` 个 cycle 的 `C_DP_RUN`
  - `1` 个 cycle 的 `C_SCORE_DONE`
  - `1` 个 cycle 的 `C_SOFTMAX_PREP`
- 这一微流程重复 `32768` 次

即本质上是：

$$2 \rightarrow 1 \rightarrow 1$$

重复 `32768` 次，而不是先 65536 个 cycle 全做 DP，再整体做 32768 个 score，再整体做 32768 个 softmax。

这点非常关键，因为它决定了后续是否存在模块级流水掩蔽空间，以及受什么数据相关约束。

### 3.3 score-pair 的定义

当前 `ROW_PAR = 2`，所以每次处理一对 query row。

对每个 `Q tile`：

- `TQ = 32`
- 每个 score-pair 对应 2 行
- 所以每个 `Q tile` 内共有：

$$QPAIR\_PER\_TILE = TQ / ROW\_PAR = 16$$

个 row-pair。

对每个 row-pair，又要遍历 `TK = 64` 个 key 行。

因此每个 `K tile` 需要处理：

$$16 \times 64 = 1024$$

个 score-pair。

全局则为：

$$8 \times 4 \times 16 \times 64 = 32768$$

个 score-pair。

---

## 4. 当前片上存储体系

### 4.1 本地 buffer 容量

从 RTL 可直接读出主要存储结构：

#### Q buffer

- `q_buf[TQ][D]`
- 容量：

$$32 \times 64 \times 16 = 32768\text{ bits} = 4\text{ KB}$$

#### K buffer（双 bank）

- `k_buf0[TK][D]`
- `k_buf1[TK][D]`
- 单 bank：

$$64 \times 64 \times 16 = 65536\text{ bits} = 8\text{ KB}$$

- 双 bank 合计：`16 KB`

#### V buffer（双 bank）

同上，双 bank 合计：`16 KB`

#### Row context

- `row_m[TQ]`：

$$32 \times 16 = 512\text{ bits} = 64\text{ B}$$

- `row_l[TQ]`：

$$32 \times 32 = 1024\text{ bits} = 128\text{ B}$$

- `row_acc[TQ][D]`：

$$32 \times 64 \times 64 = 131072\text{ bits} = 16\text{ KB}$$

#### O buffer

- `o_buf[TQ][D]`
- 容量：

$$32 \times 64 \times 16 = 32768\text{ bits} = 4\text{ KB}$$

### 4.2 主要片上存储总量

按上述主要数据结构粗略汇总：

- `Q buffer`: `4 KB`
- `K ping-pong`: `16 KB`
- `V ping-pong`: `16 KB`
- `row_acc`: `16 KB`
- `O buffer`: `4 KB`
- `row_m + row_l`: `192 B`

主存储总量约：

$$4 + 16 + 16 + 16 + 4 = 56\text{ KB}$$

即当前主线 RTL 片上显式数据存储规模大约为 **56KB 级别**。

### 4.3 存储体系的性能含义

这套体系的特点是：

- 只缓存当前 `Q tile`
- `K/V tile` 通过双 bank 做邻近 tile prefetch
- 不缓存完整的 `K` 或 `V` 矩阵

因此：

- compute 期间可以隐藏部分 `K/V` 装载延迟；
- 但从片外总流量看，`K` 和 `V` 会对每个 `Q tile` 反复读取；
- 这是一个**算力优先、片上存储适中、片外带宽重复使用较多**的设计点。

---

## 5. 理论访存流量分析

### 5.1 每个 tile 的 DMA 流量

#### Q tile

- `32 x 64 x 2B = 4096 B = 4 KB`
- beat 数：

$$4096 / 16 = 256$$

#### K tile / V tile

- `64 x 64 x 2B = 8192 B = 8 KB`
- beat 数：

$$8192 / 16 = 512$$

#### O tile 写回

- 同 Q tile：`4 KB = 256 beat`

### 5.2 一次 attention 的理论总流量

#### Q 读

Q 每个元素只对每个 `Q tile` 读一次：

$$8 \times 4KB = 32KB$$

#### K 读

对每个 `Q tile`，都要遍历全部 4 个 `K tile`：

$$8 \times 4 \times 8KB = 256KB$$

#### V 读

同 K：

$$256KB$$

#### O 写回

$$8 \times 4KB = 32KB$$

### 5.3 理论总线字节数

- 读：

$$32 + 256 + 256 = 544KB$$

- 写：

$$32KB$$

- 总计：

$$576KB$$

### 5.4 理论 DMA beat 数

- `DMA_RD_BEAT_COUNT = 34816`
- `DMA_WR_BEAT_COUNT = 2048`
- 总 bus beat：

$$36864$$

### 5.5 500MHz 下的理想总线下界

`BUS_W = 128 bit = 16 B/cycle`

若完全连续、无等待，则：

- 峰值带宽：

$$16 \times 500\text{MHz} = 8\text{ GB/s}$$

一次完整 attention 的纯总线下界为：

$$576KB / 8GB/s \approx 72\mu s$$

换成周期：

$$36864\text{ cycles}$$

这说明在当前参数下，即便总线满速，DMA 自身的理论绝对下界也仍然是三万多拍。

---

## 6. 当前 RTL 实测指标（基于最新 perf 读回）

本轮 perf 读回结果为：

- `CYCLES = 144624`
- `BUSY_CYCLES = 144624`
- `DMA_RD_CMD_COUNT = 72`
- `DMA_RD_BEAT_COUNT = 18432`
- `DMA_WR_CMD_COUNT = 8`
- `DMA_WR_BEAT_COUNT = 2048`
- `COMP_LAUNCH_COUNT = 64`
- `EXP_EVAL_COUNT = 131072`
- `MUL_EVAL_COUNT = 65536`
- `RECIP_REQ_COUNT = 256`
- `RECIP_RSP_COUNT = 256`

主状态：

- `MS_LOAD_Q = 2072`
- `MS_INIT_CONTEXT = 8`
- `MS_LOAD_K = 2072`
- `MS_LOAD_V = 2072`
- `MS_COMPUTE = 131200`
- `MS_NORMALIZE = 5120`
- `MS_WRITE_O = 2072`
- `MS_NEXT_Q = 8`

子状态：

- `CS_DP_RUN = 65536`
- `CS_SCORE_DONE = 32768`
- `CS_SOFTMAX_PREP = 32768`

### 6.1 当前主延迟构成

总周期：

$$144624$$

占比：

- `MS_COMPUTE`: 约 `90.72%`
- `MS_NORMALIZE`: 约 `3.54%`
- `MS_LOAD_Q/K/V/WRITE_O` 每项约 `1.43%`
- `MS_INIT_CONTEXT + MS_NEXT_Q` 可忽略

**结论**：当前设计明显是 **compute-bound**，不是 DMA-bound。

### 6.2 当前 compute 内部构成

有：

$$65536 + 32768 + 32768 = 131072$$

而：

$$MS\_COMPUTE = 131200$$

差值：

$$128$$

这说明：

- compute 期间绝大部分周期都在做 `DP / SCORE / SOFTMAX_PREP`
- compute 控制气泡极小
- 当前调度已经非常接近“由核心计算状态主导”

---

## 7. `CS_DP_RUN / SCORE_DONE / SOFTMAX_PREP` 的精确构成

### 7.1 公式推导

每个 score-pair 固定执行：

- `C_DP_RUN`: `DP_CHUNKS = 2` cycle
- `C_SCORE_DONE`: `1` cycle
- `C_SOFTMAX_PREP`: `1` cycle

总 score-pair 数量：

$$8 \times 4 \times 16 \times 64 = 32768$$

所以：

$$CS\_DP\_RUN = 32768 \times 2 = 65536$$

$$CS\_SCORE\_DONE = 32768$$

$$CS\_SOFTMAX\_PREP = 32768$$

### 7.2 它们之间的关系

这三者是**微步骤串行**的：

$$2 \rightarrow 1 \rightarrow 1$$

重复 `32768` 次。

所以不是“大块级串行”，而是“细粒度微流程”。

### 7.3 这是否意味着可以用流水掩蔽？

理论上有空间，但当前实现下**不能简单掩蔽**，原因是存在强 loop-carried dependency：

- `C_SOFTMAX_PREP` 会更新 `row_m / row_l / row_acc`
- 下一个 `kj+1` 的 score-pair 依赖这些刚刚更新后的状态

因此当前同一个 row-pair 的迭代有严格递推关系：

$$state(qpair, kj+1) \leftarrow state(qpair, kj)$$

这意味着：

- 如果把 `C_SOFTMAX_PREP` 变成多周期模块，下一次 `kj` 通常就必须等待；
- 也就是说，**仅仅把单个模块多周期化，并不能自动被当前控制流隐藏**；
- 若要真正隐藏多周期 latency，需要重新编排调度，例如：
  - 在多个 `qpair` 间交错发射；
  - 引入独立队列/寄存器切片；
  - 让 recurrence path 的 initiation interval 保持为 1 或接近 1。

因此这里的关键不是“能不能加流水级”，而是：

- **加了流水级之后，当前调度是否还能维持相同吞吐率。**

答案是：当前写法下，通常不能自动维持。

---

## 8. 计算量与算力分析

### 8.1 dot-product 乘法量

每个 score-pair：

- 2 行
- 每行 64 维

乘法数：

$$2 \times 64 = 128$$

总 dot 乘法数：

$$32768 \times 128 = 4194304$$

### 8.2 `SOFTMAX_PREP` 内部乘法量

每个 score-pair：

- 对 2 行、每行 64 维
- 每维执行：
  - `row_acc * exp_old`
  - `exp_new * V`

乘法数约：

$$2 \times 64 \times 2 = 256$$

总量约：

$$32768 \times 256 = 8388608$$

此外还有 `l_scaled` 的 2 个小乘法。

### 8.3 normalization 乘法量

输出元素数：

$$256 \times 64 = 16384$$

每个输出元素一次 `num * recip`。

### 8.4 当前架构的算力特征

从周期角度看，当前架构通过：

- `DP_LANES = 32`
- `ROW_PAR = 2`

把 dot-product 压到了：

- `2 cycles / score-pair`

这本质上是用大规模并行算子堆积来换低周期。

如果只看 `C_DP_RUN`：

- 每个 `DP_RUN` cycle` 约有 64 个 16x16 乘法等价并行工作
- 在 $500\text{MHz}$ 下，相当于理论并行乘法吞吐：

$$64 \times 500\text{M} = 32\text{ Gmul/s}$$

这说明当前设计在“周期性能”上很积极，但这也正是其 PPA 风险来源。

---

## 9. 访存-计算平衡与带宽分析

### 9.1 若按正确完整 K/V 访存估算

总流量：`576KB`

若总周期约仍在 `145k` 量级，则平均总线带宽约为：

$$576KB / (145k / 500MHz) \approx 1.98GB/s$$

相对理论峰值 `8 GB/s`，约为 `24.8%`。

这意味着：

- 当前设计不是峰值带宽受限；
- 主要瓶颈仍然在 compute；
- prefetch 已经把不少 DMA 等待隐藏进了 compute 内部。

### 9.2 若片上存储更大，是否有收益？

有明显收益。

当前外部流量里，最大头是：

- `K` 反复读取：`256KB`
- `V` 反复读取：`256KB`

而完整 `K` 矩阵本身只有：

$$256 \times 64 \times 2B = 32KB$$

完整 `V` 也是 `32KB`。

即：

- 如果片上能容纳完整 `K+V = 64KB`，则可把 K/V 的片外流量从 `512KB` 降到 `64KB`
- 单次 attention 的总流量可从 `576KB` 降到大约 `128KB`

这说明当前设计在片外带宽上仍有非常显著的优化空间，但代价是更大的片上 SRAM。

---

## 10. 当前 DMA 长度问题对性能/正确性的影响

### 10.1 当前现象

当前 perf 读回：

- `DMA_RD_CMD_COUNT = 72`（正确）
- `DMA_RD_BEAT_COUNT = 18432`（明显少于理论 `34816`）

### 10.2 根因

当前 `fa_attention_core` 发出的 `cmd_len` 是 16 bit；
但 `fa_dma_reader` / `fa_dma_writer` 的 `AXI_LEN_W = 8`。

对 AXI4 来说，这里还有一个更本质的问题：

- `ARLEN/AWLEN` 本身就是 8 bit；
- 合法单 burst 最大只能是 `256 beat`；
- 因此 `512 beat` 本来就不能直接作为一个 AXI4 burst 发出。

换言之，当前不是简单的“位宽写错”，而是：

- **RTL 里把一个 512-beat tile 当成单 burst 处理了；**
- **而 AXI4 规范要求必须拆成至少两个 256-beat burst。**

### 10.3 对正确性的影响

影响很可能是**实质性的**。

当前 `S_LOAD_K / S_LOAD_V / PF_DATA_K / PF_DATA_V` 的状态机都使用：

- `if (dma_rd_data_last || kv_fill_cnt == BEATS_PER_TILE_KV)`

来判断 tile 是否装满。

若总线每次只返回 256 beat，并在中点就拉高 `last`，状态机就会把“半个 tile”误认为“整个 tile 已完成”，这会导致：

- K/V tile 数据不完整；
- 后续 compute 使用半填充 buffer；
- 顶层 full-run 即使输出非零，也不代表数值正确。

因此第（3）项必须做精确数值验证，而不能只看 non-zero output。

---

## 11. `fa_attention_core` 的 PPA 风险来源

### 11.1 真正模块化复用的算子并不多

当前主线显式复用的模块只有：

- 2 个 `fa_mul_sat_q8_8`
- 4 个 `fa_exp_pwl_8seg_q1_15`
- 1 个 `fa_recip_nr_q16_16`

其余大部分乘法/乘加都直接在 `fa_attention_core` 内通过 `for` 循环与 `*` 运算符展开。

综合器通常会将其推断成大量并行算术单元，而不会“自动共享成一个乘法器多次复用”。

### 11.2 最重的组合热点

#### 热点 A：`C_DP_RUN`

- 两行并行 (`ROW_PAR=2`)
- 每行 32 lane (`DP_LANES=32`)
- 合计约 64 个乘法 + 加法归约树

#### 热点 B：`C_SOFTMAX_PREP`

这是当前最值得警惕的热点：

- 对 `D=64` 全向量并行更新 `acc`
- 每个维度包含：
  - `acc * exp_old`
  - `exp_new * V`
- 两行同时处理

单拍推断出来的算术规模非常大。

#### 热点 C：`S_NORMALIZE`

- `NORM_LANES=8`
- 每拍最多 8 路 `num * recip`

虽然周期占比不高，但也会带来明显的宽乘法硬件。

### 11.3 STA 覆盖现状

当前仓库已有若干小模块/实验模块的综合/STA结果，但：

- `fa_attention_core` 本身未形成独立 STA 结果闭环
- `fa_attention_ip_top` 当前配置也不是最新完备版

因此当前可以说：

- 周期画像已较清晰
- 但主线 PPA 画像尚未闭环

---

## 12. `fa_attention_core` 是否值得合理拆解

答案是：**非常值得，且应优先从功能边界清晰、存在显著算术热点的阶段拆。**

### 12.1 推荐的拆解边界

#### 方向 A：dot-product engine

将 `C_DP_RUN` 中的 32-lane x 2-row 点积阵列独立成模块：

- 便于单模块 STA
- 便于探索 `DP_LANES = 16 / 32 / 64` 的 PPA-周期折中
- 便于考虑内部加法树寄存化

#### 方向 B：score/softmax update engine

将 `C_SCORE_DONE + C_SOFTMAX_PREP` 拆为一个独立更新核：

- score scale / mask
- `m/l` 更新
- `acc` rescale + `P*V`

这是当前最适合做“结构化优化”的区域，因为：

- 功能边界清晰；
- 乘法器密度高；
- 既影响周期，也影响面积和时序。

#### 方向 C：normalization engine

把 `S_NORMALIZE` 单独向量化：

- 便于探索 `NORM_LANES`
- 便于独立流水化/复用倒数接口
- 风险相对较低

#### 方向 D：tile load/store scheduler

将 `Q/K/V/O` 装载与 burst 拆分逻辑独立，使 DMA 规范处理（如 512-beat tile 拆 burst）和 compute 分离。

### 12.2 拆解后对流水化的理论意义

拆成模块后，并不意味着一定能隐藏延迟；但有两个重要收益：

1. **单模块可独立寄存化**
   - 先解决时序与面积评估问题
2. **更容易做跨模块队列化/分阶段流水**
   - 例如 dot -> score -> update 的 stage interface

### 12.3 但要注意的数据依赖约束

当前 `softmax` 是 online recurrence：

- `row_m`
- `row_l`
- `row_acc`

都对同一 row-pair 的下一个 `kj` 形成强依赖。

因此：

- 单纯把某一阶段改成多拍，并不会自动被当前调度隐藏；
- 要隐藏 latency，需要额外引入：
  - 多 row-pair 交错调度
  - 环形队列/forwarding
  - 模调度或类似 modulo scheduling 的思想

换言之，**拆解 + 流水化**是有价值的，但必须同时考虑调度重排，而不是只对算子本身打寄存器。

---

## 13. 参数变化对性能指标的理论影响

### 13.1 `DP_LANES`

- `CS_DP_RUN \propto D / DP_LANES`
- 增大 `DP_LANES`：
  - 周期下降
  - 面积/扇出/加法树复杂度上升

### 13.2 `ROW_PAR`

- `score-pair 数量 \propto TQ / ROW_PAR`
- 增大 `ROW_PAR`：
  - `CS_*` 周期减少
  - 但 `C_SCORE_DONE` / `C_SOFTMAX_PREP` 单拍硬件规模近似线性增大

### 13.3 `NORM_LANES`

- `MS_NORMALIZE \propto D / NORM_LANES`
- 增大 `NORM_LANES` 能回收 normalization 周期，但会增加宽乘法并行数

### 13.4 `TK`

增大 `TK`：

- 减少 `NUM_K_TILES`
- 降低 tile 切换开销
- 提高单 tile buffer 容量需求
- 并且会直接挑战 AXI burst 分段逻辑

### 13.5 `TQ`

增大 `TQ`：

- 减少 `NUM_Q_TILES`
- 降低 `S_LOAD_Q / INIT / WRITE_O / NEXT_Q` 的切换频率
- 但增加 `Q/O/row_acc` 等片上存储规模

### 13.6 `BUS_W`

增大 `BUS_W`：

- 降低 `BEATS_PER_ROW`
- 降低 DMA beat 数
- 提高 peak bandwidth
- 但会加大总线对齐/pack/unpack 逻辑复杂度

---

## 14. 当前架构的初步结论

### 14.1 结论 A：当前主线是 compute-bound

按当前参数与 perf 结果，主周期明显由 `MS_COMPUTE` 主导，DMA 主要被 prefetch 隐藏。

### 14.2 结论 B：当前主线不是“控制态拖慢”，而是“高并行算子主导”

`MS_COMPUTE` 几乎完全由 `CS_DP_RUN / C_SCORE_DONE / C_SOFTMAX_PREP` 组成，控制开销很小。

### 14.3 结论 C：当前 PPA 风险不能仅由小模块 STA 推断

主线 `fa_attention_core` 的大量推断乘法器/乘加树还没有形成真正的 STA/PPA 闭环，存在明显不确定性。

### 14.4 结论 D：512-beat tile 不能直接映射为单个 AXI4 burst

这不是“小 bug”，而是当前 DMA 实现模型中的架构性问题，必须通过 burst 拆分来修复。

---

## 15. 建议的后续工作顺序

1. **先修 DMA burst 拆分问题并做 top-level 数值正确性验证**
2. 基于修正后的 top-level 重新采样 perf / cycles / traffic
3. 再做主线 `fa_attention_core` 的独立综合/STA评估
4. 然后围绕以下几个方向选择优化：
   - `DP_LANES / ROW_PAR / NORM_LANES` 参数折中建模
   - `K/V` 更大片上缓存以减少外存流量
   - `C_SOFTMAX_PREP` 的结构拆分与局部流水化
   - 多 row-pair 交错调度，以尝试隐藏 recurrence path latency

---

## 16. 一句话总结

当前 RTL 已经具备较清晰的高吞吐 tile-based attention 主线，周期上主要受 `DP + online softmax/PV` 计算主导；但其主线 datapath 集成度很高、推断算术单元非常重，PPA 风险尚未真正闭环，同时 top-level DMA 还存在 512-beat tile 未按 AXI4 burst 规则拆分的问题，这会直接影响当前顶层数值正确性与性能画像可信度。
