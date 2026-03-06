# 02 当前 RTL 设计与数据流说明

## 2.1 当前主线设计的总体结构

当前 baseline 实现由以下几层组成：

1. **顶层集成**：`fa_attention_ip_top`
   - 对外提供 AXI4-Lite 控制接口；
   - 对外提供 AXI4 Master DMA 数据接口；
   - 内部集成寄存器模块、DMA reader/writer 与 attention core。

2. **控制与寄存器层**：`fa_axi_lite_regs`
   - 负责 `CTRL / STATUS / CFG / BASE / STRIDE / NEG_LARGE / SCALE / CYCLES` 等寄存器；
   - 将软件可见配置转换成 `fa_attention_core` 的启动与参数输入。

3. **数据搬运层**：`fa_dma_reader` / `fa_dma_writer`
   - 负责把 Q/K/V 从内存搬到计算核的数据流接口；
   - 负责把 O 写回内存。

4. **计算核心**：`fa_attention_core`
   - 以 tile 为单位完成 Q 读入、K/V 分块、QK 点积、online softmax、PV 累加、归一化、O 写回；
   - baseline 参数默认：`SEQ_LEN=256`, `D=64`, `TQ=32`, `TK=64`。

## 2.2 FlashAttention-style 约束在当前 RTL 中的体现

题目要求必须体现三点：

1. 禁止显式存储 `S×S` 注意力矩阵；
2. 必须使用 online softmax；
3. 必须分块（tiling）处理 K/V。

当前 RTL 对这三点的对应关系如下。

### (1) 不显式存储 `S×S`

当前主线 RTL 没有为 `256×256` 的 `score` 或 `P` 矩阵分配完整存储阵列。当前存储结构主要是：

- `q_buf[TQ][D]`
- `k_buf0/1[TK][D]`
- `v_buf0/1[TK][D]`
- `row_m[TQ]`
- `row_l[TQ]`
- `row_acc[TQ][D]`
- `o_buf[TQ][D]`

这些都属于 tile 级/行级上下文，而不是完整注意力矩阵缓存。

### (2) online softmax

当前主线 `fa_attention_core` 内部直接维护每个 query 行的：

- `m`：行内最大值；
- `l`：归一化分母累计项；
- `acc`：加权输出累计项；

即使当前 top 数据通路没有直接实例化 `fa_row_reduction_core`，它所执行的仍然是同一类 online softmax 递推思想。

### (3) K/V 分块

当前主线采用：

- `TQ = 32`
- `TK = 64`

即每次先装入一个 Q tile，再分 4 个 K/V tile 完成整段序列的覆盖。这与题目要求的 tiled FlashAttention 数据流一致。

## 2.3 当前核心数据流

一次 baseline 运行的大致流程为：

1. 读入一个 `Q tile`（32 行）；
2. 初始化该 tile 对应 32 行的 `m/l/acc` 上下文；
3. 依次读入 4 个 `K tile` 与 4 个 `V tile`；
4. 对每个 `K/V tile`：
   - 计算 `QK^T` 的 tile 内点积；
   - 叠加 scale 与 causal mask；
   - 进行 online softmax 更新；
   - 同步累加 `P*V` 到 `row_acc`；
5. 全部 K/V tile 处理完成后，对当前 32 行做归一化，生成 `O tile`；
6. 把 `O tile` 通过 DMA 写回；
7. 对全部 8 个 Q tile 重复以上流程。

## 2.4 当前存储结构与面积风险的关系

当前 `fa_attention_core` 里的片上存储若以寄存器方式综合，主要位数大致为：

| 结构 | 位数 |
|---|---:|
| `q_buf[32][64]` | 32,768 |
| `k_buf0/1[64][64]` | 131,072 |
| `v_buf0/1[64][64]` | 131,072 |
| `row_acc[32][64]`（64-bit） | 131,072 |
| `o_buf[32][64]` | 32,768 |
| `row_m/row_l` 等 | 1,536 |
| **合计** | **460,288 bits** |

这说明：

- 当前设计在“**不存储 `S×S` 矩阵**”这点上是成立的；
- 但这**不等于**顶层面积自然安全；
- 若这 46 万余 bit 大部分被综合为触发器/寄存器阵列，则按照题目“含存储折算”的口径，top 级面积仍存在显著风险。

## 2.5 为什么 `fa_row_reduction_core` 的 STA 不能直接代表 top 级 STA

这点需要单独强调。

当前主线 `fa_attention_core`：

- 并不是直接实例化 `fa_row_reduction_core` 来完成 top 路径；
- 而是在 core 内部内联实现了点积、softmax 更新、PV 累加和最终归一化逻辑。

因此：

1. `fa_row_reduction_core` 的模块级 STA 结果不能直接当作 top 级 STA 结果；
2. 但它仍然是有价值的**热点 proxy**：
   - 因为其内部包含了和 top 同类的 `online softmax + recip + norm` 算术结构；
   - 所暴露出的瓶颈方向与主线核心是一致的，即 **softmax recurrence**。

## 2.6 本轮对 RTL 状态的结论

截至本轮报告，主线 RTL 的状态可以概括为：

- reciprocal 的 10 级流水优化已落地；
- row reduction 的 10 级对齐逻辑已落地；
- baseline attention core 的完整功能、周期、误差结果已经可在主线环境中直接复现；
- 但若目标从“通过 baseline”升级到“全核心 500MHz 闭合”，则必须进入下一阶段的微架构研究。