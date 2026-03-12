# FlashAttention IP 设计、验证与综合报告（0312 增补版）

> 说明：本报告是基于 [docs/report_0310/大纲.md](../report_0310/%E5%A4%A7%E7%BA%B2.md) 的 0312 增补版。除第 9 章“Bonus 功能实现”按当前各独立 bonus 分支的真实落地状态重新补全外，其余章节均严格沿用 0310 版本的章节结构与技术口径，不再重复改写，以避免把中间探索结论误写成当前最终结论。

## 1. 简介

本章内容沿用 [docs/report_0310/大纲.md](../report_0310/%E5%A4%A7%E7%BA%B2.md#1-%E7%AE%80%E4%BB%8B) 的对应章节全文，不做改写。

## 2. 项目进度总结

本章内容沿用 [docs/report_0310/大纲.md](../report_0310/%E5%A4%A7%E7%BA%B2.md#2-%E9%A1%B9%E7%9B%AE%E8%BF%9B%E5%BA%A6%E6%80%BB%E7%BB%93) 的对应章节全文，不做改写。

## 3. 具体设计方案

本章内容沿用 [docs/report_0310/大纲.md](../report_0310/%E5%A4%A7%E7%BA%B2.md#3-%E5%85%B7%E4%BD%93%E8%AE%BE%E8%AE%A1%E6%96%B9%E6%A1%88) 的对应章节全文，不做改写。

## 4. 附加模块的设计

本章内容沿用 [docs/report_0310/大纲.md](../report_0310/%E5%A4%A7%E7%BA%B2.md#4-%E9%99%84%E5%8A%A0%E6%A8%A1%E5%9D%97%E7%9A%84%E8%AE%BE%E8%AE%A1) 的对应章节全文，不做改写。

## 5. 功能验证——Testbench 仿真与波形说明

本章内容沿用 [docs/report_0310/大纲.md](../report_0310/%E5%A4%A7%E7%BA%B2.md#5-%E5%8A%9F%E8%83%BD%E9%AA%8C%E8%AF%81testbench-%E4%BB%BF%E7%9C%9F%E4%B8%8E%E6%B3%A2%E5%BD%A2%E8%AF%B4%E6%98%8E) 的对应章节全文，不做改写。

## 6. UVM 验证——模块功能和完整性测试

本章内容沿用 [docs/report_0310/大纲.md](../report_0310/%E5%A4%A7%E7%BA%B2.md#6-uvm-%E9%AA%8C%E8%AF%81%E6%A8%A1%E5%9D%97%E5%8A%9F%E8%83%BD%E5%92%8C%E5%AE%8C%E6%95%B4%E6%80%A7%E6%B5%8B%E8%AF%95) 的对应章节全文，不做改写。

## 7. 算法实现架构建模

本章内容沿用 [docs/report_0310/大纲.md](../report_0310/%E5%A4%A7%E7%BA%B2.md#7-%E7%AE%97%E6%B3%95%E5%AE%9E%E7%8E%B0%E6%9E%B6%E6%9E%84%E5%BB%BA%E6%A8%A1) 的对应章节全文，不做改写。

## 8. IP 核接入大模型推理

本章内容沿用 [docs/report_0310/大纲.md](../report_0310/%E5%A4%A7%E7%BA%B2.md#8-ip-%E6%A0%B8%E6%8E%A5%E5%85%A5%E5%A4%A7%E6%A8%A1%E5%9E%8B%E6%8E%A8%E7%90%86) 的对应章节全文，不做改写。

## 9. Bonus 功能实现

与 0310 报告不同，本章不再只给出“bonus 方向展望”，而是按赛题 [problem.md](../../problem.md#L106-L114) 中定义的 9 个 Bonus 逐项盘点当前仓库的真实落地状态。这里采用的判断口径是：**必须基于独立版本/独立分支的实际源码、提交历史与可复现验证结果，而不是只依据中间阶段文档。** 按这一口径，截至 2026-03-12，当前仓库已在独立 bonus 版本上完成 **Bonus 2、3、4、5、9 共 5 项**；其中 `main` 与 `baseline` 仍保持纯 baseline 主线，不混入 bonus 改动。

为避免混淆，这里先给出总体结论表。

| Bonus | 题目定义 | 当前状态 | 对应分支/提交 | 说明 |
|---|---|---|---|---|
| 1 | BF16/FP16 版本 | 仅分析未实现 | `exp/route-a-low-precision-research`（与 `main` 同指针） | 只有路线研究，没有 RTL 落地 |
| 2 | 多 head 支持 | 已完成 | `exp/bonus2-mha` / `de91781` | 顺序多 head 调度，single-core sequential MHA |
| 3 | 更长序列 `S=512` | 已完成 | `exp/padding-mask-s512` / `9132df2`、`46ba878` | 已完成 core 与 top/IP 级验证 |
| 4 | Padding mask | 已完成 | `exp/padding-mask-s512` / `9132df2` | `valid_len` 端到端支持，修复过真实 bug |
| 5 | 其他定点格式 | 已完成 | `exp/padding-mask-s512` / `dd49364`、`46ba878` | 支持 `Q6.10/Q4.12` 外部格式 |
| 6 | Dropout | 未开始 | — | 尚无 RTL、验证或接口痕迹 |
| 7 | 更低精度 `INT8/FP8` | 仅分析未实现 | `exp/route-a-low-precision-research`（与 `main` 同指针） | 有路线讨论，无实现 |
| 8 | AXI4-Stream 接口 | 仅分析未实现 | — | 当前仍以 AXI-Lite + AXI Master DMA 为主 |
| 9 | DMA/任务队列 | 已完成 | `exp/bonus9-task-queue` / `e0c8c83` | 已从 P1 ping-pong 演进到 P2 true FIFO |

因此，本仓库“当前 5 项 bonus 完成情况”的最合理解释是：

1. `exp/bonus2-mha` 完成 Bonus 2；
2. `exp/padding-mask-s512` 同时完成 Bonus 3、4、5；
3. `exp/bonus9-task-queue` 完成 Bonus 9；
4. 其余 Bonus 仍处于研究或未启动状态；
5. 这些 bonus 均以**独立版本**形式存在，符合题目要求“Baseline 通过后另开版本开展”。

### 9.1 Bonus 1：BF16/FP16 版本

Bonus 1 要求在 Baseline 的定点版本之外，额外实现 BF16 或 FP16 attention，并给出误差与性能对比。从当前仓库真实状态看，这一路线**已经被研究，但尚未进入实现阶段**。

首先，从分支状态上看，当前本地存在 `exp/route-a-low-precision-research`，但其相对 `main` 没有任何独有实现提交；换言之，它目前仍是一个“路线研究分支名”，而不是带有实际 RTL 差异的实现分支。其次，从源码上看，仓库中并不存在 BF16/FP16 版本的 `exp`、倒数、softmax、归一化、cast/rounding 或异常值处理硬件路径，当前所有活动主线与 bonus 分支仍都建立在 Q8.8 输入、较高位宽中间累加和 Q16.16 倒数链路之上。

从文档口径上，0311/0312 的相关材料更接近“研究路线选择”而非“实现验收结论”。当前可信结论应写成：**Bonus 1 已完成路线分析，但没有独立 RTL 落地，也没有误差/周期/面积三项完整对比数据。** 这也意味着若后续要继续推进，需要至少补齐如下四类工作：

1. 重新设计 BF16/FP16 的乘法、累加、缩放与归一化链路；
2. 明确 softmax / `exp` / reciprocal 的浮点或混合精度实现策略；
3. 建立与 Q8.8 baseline 可直接对比的误差与性能回归；
4. 在寄存器、DMA 和软件驱动层补齐数据格式选择与转换语义。

因此，在正式报告中，Bonus 1 应被归类为：**已完成方案论证，尚未工程化实现**。

### 9.2 Bonus 2：多 head 支持

Bonus 2 对应题目中的“支持 `head=4/8`，并扩展 head 维度与地址/stride 管理”。当前这一项已经在独立分支 `exp/bonus2-mha` 上完成，关键实现提交为 `de91781`（`feat: 顺序mha流实现`），后续又补充了验证分析文档与子模块指针更新。

这一路线的实现策略非常明确：**不改 `fa_attention_core` 的单 head 计算本体，而是在 top 级增加一个 head 顺序调度器，通过 head 基址偏移顺序复用同一个 core。** 从架构风格上看，这不是“并行 multi-head array”，而是“single-core sequential MHA”。其核心优点在于：改动集中、容易归因、不会破坏已稳定的单 head baseline 算法核。

实现上，主要改动集中在两个位置。其一，`fa_axi_lite_regs` 新增了 `REG_NUM_HEADS=0x44` 与 `REG_HEAD_STRIDE=0x48`，前者用于指定本次运行的 head 数，后者用于指定相邻两个 head 的地址跨度；当 `HEAD_STRIDE=0` 时，top 级还会自动退回到 `SEQ_LEN * STRIDE_BYTES` 的默认 head 间距。其二，`fa_attention_ip_top` 新增 `effective_num_heads`、`effective_head_stride_bytes`、`active_head_idx`、`launch_pending`、`completed_head_cycles`、`run_cycles_hold` 等控制寄存变量，将外部一次 `START` 展开成多个内部 `core_start_pulse`，并把 `DONE/CYCLES` 聚合到整个多 head run 上。

验证层面，这一分支不只是“能跑 2 个 head”，而是已经完成了更完整的 head 数扩展验证：

- 在顶层 cocotb 中补充了 `NUM_HEADS/HEAD_STRIDE` 的寄存器默认值与 R/W 行为测试；
- 新增 `test_multihead_two_head_full_run`；
- 进一步复用 top full-run 框架完成 `head=4` 与 `head=8` 的验证。

当前最可信的数据点如下，均来自该分支的总结文档与分支级回归结果：

| 配置 | 周期 | 关键计数器 | 相对 FP32 |
|---|---:|---|---|
| `head=2` | `171856` | `comp_launch=128`，`recip_req=512`，`wr_cmd=16` | `MaxAE=0.006799` |
| `head=4` | `343712` | `comp_launch=256`，`recip_req=1024` | `MAE=0.002401`，`MaxAE=0.008180` |
| `head=8` | `687424` | `comp_launch=512`，`recip_req=2048` | `MAE=0.002369`，`MaxAE=0.008180` |

这些结果有两个明确含义。第一，当前实现已经满足了题目“支持 `head=4/8`”的基本要求。第二，由于它采用的是顺序复用单核的形式，周期与 `comp_launch`/`recip_req` 等指标会近似按 head 数线性放大，这是一种可预期且可解释的结果，而不是验证异常。换言之，这个 bonus 已经完成，但其完成形态是**以最小侵入实现标准 MHA 支持**，而非追求更激进的跨 head overlap 或并行多核版本。

后续如果继续推进 Bonus 2，更自然的方向包括：增加多 seed / 多 causal 配置覆盖；给 `run_count` 与 perf 统计做更细粒度的 head 级拆账；以及评估是否值得在未来引入跨 head overlap 或共享 buffer 调度。不过这些都属于增强项，而不影响当前“Bonus 2 已完成”的结论。

### 9.3 Bonus 3：更长序列 `S=512`

Bonus 3 要求支持比 baseline 更长的序列长度，并在不显式存储 `S×S` 中间矩阵的前提下保持 FlashAttention-style 的计算约束。当前这一项已在独立分支 `exp/padding-mask-s512` 上完成，关键起始提交为 `9132df2`（引入 `valid_len` 与 `S=512` 验证目标），在 `46ba878` 之后又补齐了更完整的 top/IP 级闭环。

这一分支的价值在于：它不是单独为了 `S=512` 建一个完全不同的数据通路，而是尽量沿用当前主线的 tile / online softmax / DMA 组织，只做必要的参数化扩展。也就是说，这个 bonus 的工程思想不是“另写一版长序列核心”，而是验证当前架构是否具备向更长序列平滑扩展的可能性。

从实现面看，`fa_attention_core` 被参数化到 `SEQ_LEN=512`，同时仍维持 `D=64`、`TQ=32`、`TK=64` 的基本组织，因此序列维度只是在 tile 外层循环数上翻倍，而不会引入显式 attention matrix 缓存。对应的 cocotb 目标包括：

1. `fa_attention_core_s512`，用于验证 core 级参数化闭合；
2. `fa_attention_ip_top_s512`，用于验证 top/IP 级带 DMA 和 perf 计数器的整链闭环。

当前可信的最终数据以 top/IP 级为准。该分支文档明确记录：

- `cycles=307024`
- `busy=307024`
- `rd_cmd=528`
- `rd_beat=135168`
- `wr_cmd=16`
- `wr_beat=4096`
- `compute=270336`
- `dp=266240`
- `score=131072`
- `softmax=131072`
- 相对 fixed-like：逐点精确一致
- 相对 FP32：`MAE=0.002235`，`MaxAE=0.006685`

需要特别说明的是，这里的 `307024 cycles` 不应与 baseline 的 `<300k cycles` 约束直接类比，因为问题规模已经从 `S=256` 扩展到 `S=512`。恰恰相反，这组数据说明：**当前 tile 化 + online softmax 架构在序列长度翻倍后仍能保持功能正确与可解释的吞吐扩展。** 这正是 Bonus 3 的价值所在。

因此，对 Bonus 3 的正式结论可以写成：当前仓库已经完成 `S=512` 的参数化扩展验证，而且不只是 core 级“局部跑通”，而是已经完成 top/IP 级带 DMA/perf 的全路径验证；尚未补齐的部分主要是更系统的 PPA/带宽报告和更多随机种子的交叉覆盖，而不是功能本身。

### 9.4 Bonus 4：Padding mask

Bonus 4 对应“支持输入有效长度 `L<=S` 的 padding mask”。当前这一项同样已在 `exp/padding-mask-s512` 分支上落地，其关键实现提交为 `9132df2`。与一些只在软件前处理做 padding 的方案不同，这一版本是从 RTL 级把 `valid_len` 明确纳入控制面与数据路径。

具体来说，分支中新增了 `REG_VALID_LEN = 0x10`，默认值为 `256`。随后，`fa_axi_lite_regs` 输出 `o_valid_len`，顶层再将该值传给 `fa_attention_core`。在核心内部，padding mask 的实现逻辑分成三层：

1. 对超出 `valid_len` 的 key 位置，直接打成 `i_neg_large_q8_8`，使其在 softmax 中等价于 `-inf`；
2. 对超出 `valid_len` 的 query 行，不再发起有效 softmax 更新；
3. 在 normalize / writeback 阶段，对无效 query 行直接写零，避免输出 buffer 残留脏值。

这一项 bonus 的一个重要特点是：它不只是“加了一个寄存器然后回归通过”，而是经过了真实 bug 修复。分支文档里明确记录了两类问题：其一，`valid_len=192` 时 top 回归在 compute 阶段超时，根因是 tile 内无效 `row-pair` 未被预先置 done，导致批次等待永远不会到达的 softmax 完成信号；其二，仿真虽然能结束，但 padded 区域输出出现脏值，根因是无效 query 行未参与正常 normalize，却也没有被显式清零。对应修复后，padding mask 才真正形成了可信闭环。

当前分支级最终验证结果为：

- 使用 `TOP_TEST_VALID_LEN=192` 的 top 级回归通过；
- `cycles=73880`
- `busy=73880`
- `compute=56944`
- `norm=4480`
- `dp=53048`
- `score=24576`
- `softmax=24576`
- `recip_req=192`，`recip_rsp=192`
- fixed-like：逐点精确一致
- 相对 FP32：`MAE=0.001868`，`MaxAE=0.006583`

这些结果说明，随着有效长度从 `256` 缩短到 `192`，关键计算与归一化计数器都会同步下降，这既验证了 padding mask 的语义正确，也说明该机制已经真正影响到系统级工作量，而不是仅仅做了输出后处理。

因此，Bonus 4 的当前结论应写成：**已完成 RTL 级 `valid_len`/padding-mask 支持，且经过 bug 修复后已形成 top/IP 级端到端闭环。** 后续可继续补充非法 `valid_len` 配置的异常语义、更大覆盖范围的 `valid_len` 点回归，以及与驱动寄存器文档的进一步正式化，但这不影响其“已完成”状态。

### 9.5 Bonus 5：其他定点格式

Bonus 5 要求在 baseline 的 `Q8.8` 之外，额外支持其他等价定点格式，并给出误差与性能对比。当前这一项也已在 `exp/padding-mask-s512` 分支上完成，起始提交为 `dd49364`（增加 bonus data format support），随后在 `46ba878` 中补齐了更完整的验证闭环。

这一 bonus 的实现策略具有明显的工程折中：**外部张量格式可切换，但内部主计算 datapath 保持统一 Q8.8。** 具体做法是新增 `REG_DATA_FMT = 0x0C`，支持以下编码：

- `0`：`Q8.8`（默认）
- `1`：`Q6.10`
- `2`：`Q4.12`

随后，在 DMA 入口侧把外部 `Q/K/V` 按所选格式转换为内部统一 `Q8.8`，内部 attention 核继续沿用既有的 `Q8.8 + 高位累加 + online softmax + Q16.16 reciprocal` 路径，最终在 `O` 写回前再从内部 `Q8.8` 转回目标外部格式。这意味着当前 Bonus 5 的实质是“外部格式桥接”，而不是“内部 datapath 全链路多格式化”。

从赛题定义看，这一实现已经满足要求，因为题目只要求“额外支持等价定点格式，并给出误差与性能对比”，并未强制要求内部算术必须完全以对应格式运行。工程上，这样的选择也最稳健：它避免了重新设计整条主数据通路，却能让系统在接口层面验证更多定点编码形式。

验证结果方面，当前已完成如下几组分支级回归：

1. `TOP_TEST_DATA_FMT=1`（`Q6.10`）top 回归通过；
2. `TOP_TEST_DATA_FMT=2`（`Q4.12`）top 回归通过；
3. `TOP_TEST_DATA_FMT=1 TOP_TEST_VALID_LEN=192` 组合回归通过；
4. `CORE_TEST_DATA_FMT=1 MODULE=fa_attention_core_s512` 组合回归通过。

其中最具代表性的 top/IP 级数据为：

- `Q6.10`：`cycles=85928`，相对 FP32 `MAE=0.004218`，`MaxAE=0.009086`
- `Q4.12`：`cycles=85928`，相对 FP32 `MAE=0.004218`，`MaxAE=0.009086`
- `Q6.10 + valid_len=192`：`cycles=73880`，相对 FP32 `MAE=0.003118`，`MaxAE=0.009086`
- `Q6.10 + S=512(core)`：`Core done after 306834 cycles`，相对 FP32 `MAE=0.004772`，`MaxAE=0.019297`

这些结果说明两件事。第一，新的外部定点格式支持并没有破坏主线周期；第二，即使经过外部格式换算，相对 FP32 的误差仍远低于赛题门限 `MAE<=0.03`、`MaxAE<=0.10`。在该分支的文档中也专门解释了一个容易误读的现象：`Q6.10` 与 `Q4.12` 出现相同的 FP32 误差，并不表示实现异常，更多是因为当前测试激励本来就在 `Q8.8` 网格上，额外格式只是做了精确的存储映射，再在入口回到统一内部格式。

因此，Bonus 5 当前可以被正式归类为：**已完成，且实现方式为接口层多格式支持 + 内部统一 Q8.8 计算。** 若后续还想把这一项做得更“深”，可以考虑进一步推进内部 datapath 的真正多格式化，但这已经超出题目最低定义。

### 9.6 Bonus 6：Dropout（训练模式）

Bonus 6 要求在 softmax 后加入 dropout，并明确随机数产生方式与可复现种子。这一项在当前仓库中**尚未开始**。

首先，当前所有活动主线和 bonus 分支都以推理路径为中心，不区分训练/推理模式，也没有在 softmax 后插入 dropout mask 的任何 datapath。其次，仓库中不存在与 dropout 相关的随机数发生器、seed 寄存器、重复性控制、mask bitstream 或 post-softmax re-scale 逻辑。再次，现有的 cocotb/UVM/Verilator 环境也没有任何一项回归针对“固定 seed 下 dropout 行为可复现”或“训练态输出统计特征正确”这类问题展开。

从工程角度看，Dropout 并不是一个“只需加几位寄存器”的小改动，因为它至少会引入以下新工作：

1. 新增训练模式开关与种子配置接口；
2. 在 softmax 概率之后插入随机 mask 与缩放逻辑；
3. 解决随机数分布、吞吐率与硬件代价之间的平衡；
4. 定义“可复现”的验证口径；
5. 重新审视误差与参考模型对比方式。

对于当前项目而言，考虑到赛题 baseline 目标和既有 bonus 优先级，Dropout 的缺席是合理的：它对展示价值和推理性能帮助有限，却会显著扩大验证与接口复杂度。因此，在正式报告中，Bonus 6 最合适的表述应是：**未开始，当前仓库中没有 RTL、验证或接口层面的实际实现痕迹。**

### 9.7 Bonus 7：更低精度（INT8/FP8 思路）

Bonus 7 要求参考 FlashAttention-3 的低精度策略，实现块量化/分块缩放等更低精度路径，并给出误差收益。当前这一项和 Bonus 1 类似，已经进入研究讨论，但**并未形成独立实现版本**。

从分支现状看，唯一相关的分支仍是 `exp/route-a-low-precision-research`，但该分支当前与 `main` 完全同指针，没有独有 RTL 或测试差异。也就是说，它更多是“保留方向名”，而不是已经承载了真实低精度实现。仓库现有 0312 文档确实讨论了 BF16/FP16 与 INT8/FP8 路线的优先级、侵入性与收益预期，但这些内容本质上都属于“立项分析”，不能直接写成“已完成 Bonus 7”。

从源码维度看，也完全看不到低精度块量化真正落地的痕迹。目前没有：

- block scale metadata 的存储与搬运；
- INT8/FP8 的 dot-product datapath；
- scale-dequant / rescale 逻辑；
- 与低精度相关的 softmax/normalize 数值稳定策略；
- 基于低精度格式的 cocotb 或 Verilator 回归。

因此，当前最可信的表述应该是：**Bonus 7 已有研究方向与技术路线比较，但尚未开始 RTL 落地。** 这一结论也与当前项目的阶段性重点一致：在 baseline 与 5 个高展示度/低风险 bonus 已经闭环的前提下，更低精度路线仍属于后续可选研究项，而不是当前仓库的既有成果。

### 9.8 Bonus 8：AXI4-Stream 数据接口

Bonus 8 要求在 baseline 的 AXI4 Master + DMA 数据模式之外，额外提供 AXI4-Stream 输入/输出接口，以便与其他 IP 级联。当前这一项在仓库中**仅有分析与取舍，没有实际实现**。

当前主线和所有已完成 bonus 分支都沿用了统一的控制/数据平面结构：控制面使用 AXI-Lite，数据面使用 AXI Master DMA。仓库中没有出现新的 `TVALID/TREADY/TLAST` 风格顶层端口，也没有 stream 输入缓存、包格式定义、backpressure 策略或 DMA/AXIS 双模式切换逻辑。已有的 0311/0312 设计讨论更倾向于优先把 `valid_len`、`S=512`、多 head 和任务队列这些更直接关联赛题展示面的 bonus 做完，而不是过早引入新的数据接口协议。

从工程收益角度看，这一取舍是合理的：AXI4-Stream 更适合用于 IP 之间紧耦合级联，而当前项目的主展示路径仍是“主机配置 + DMA 搬运 + 单 attention IP”。因此在没有更完整 SoC 级联背景之前，AXIS 接口虽然有系统意义，但不是最优先的 bonus。

因此，在正式报告中对 Bonus 8 的写法宜保持克制：**当前只完成了接口价值和系统适用场景的分析，没有开始 RTL 级实现。** 若未来要推进，需要补齐至少五部分内容：stream 端口定义、输入输出打包协议、内部 buffer/backpressure 设计、DMA 版与 AXIS 版的共存策略，以及 top/IP 级验证用例。

### 9.9 Bonus 9：DMA / 任务队列

Bonus 9 对应“支持多次 attention 连续执行（队列/链式配置），减少主机交互”。这一项是当前 0312 增补里最重要的新变化之一，因为它不仅形成了独立分支实现，而且在同一条分支内部经历了从 **P1 ping-pong / shadow-next 原型** 到 **P2 true FIFO task queue** 的完整演进。当前最终可信状态以 `exp/bonus9-task-queue` 分支尖端的 `e0c8c83` 为准，而不是早期原型文档中的中间结论。

首先需要澄清一个文档层面的陷阱：`docs/20260312_bonus9_task_queue_progress.md` 的后半部分仍保留了 P1 时期“当前+next 只是乒乓、尚未完成 true queue”的历史说明，但这并不是当前最终状态。该文档顶部已经明确写明：P2 的 true FIFO 已完成实现、参数化与顶层回归；这也是当前分支源码所对应的事实。

从实现结构看，当前 Bonus 9 已经放弃了双倍 `NEXT_*` 接口的设计，转而采用更干净的“单套 staging descriptor + 内部 parameterized FIFO + active-task scheduler”方案：

1. AXI-Lite 侧只保留 baseline 风格的单套任务描述寄存器，作为 staging descriptor；
2. 通过 `REG_QUEUE_CMD[0]` 显式 enqueue 当前 staging descriptor；
3. 顶层内部维护 `FIFO_DEPTH` 可参数化的 pending FIFO，默认深度为 `4`；
4. scheduler 在 core 空闲时自动 dequeue，并把 popped descriptor 装载到 active task register bank；
5. `REG_TASK_ACCEPT_COUNT / DONE_COUNT / ERROR_COUNT` 区分 task 粒度；
6. `QUEUE_STATUS` 同时暴露 `empty/full/ready/busy_exec/count/free_slots` 以及 sticky error 位。

该结构的关键优势在于：它把“任务提交”和“任务执行”彻底解耦。Host 不再需要为每个任务单独写一次 `START`；只要队列可接收，就可以按 `ready-valid` 风格轮询 `QUEUE_STATUS.ready` 后反复写 staging regs，再通过 `QUEUE_CMD.enqueue` 提交。之后所有连续任务都会由顶层 scheduler 自动消费。

在异常语义上，当前实现也已经相当完整：

- descriptor 入队前会检查 `stride_bytes != 0`、`scale_q8_8 != 0`、`Q/K/V/O` 16B 对齐、`stride_bytes` 16B 对齐；
- 非法 descriptor 会被拒收，并置位 `queue_desc_error_sticky=1`、`last_error=3`；
- 队列满时继续 enqueue 会置位 `queue_overflow_sticky=1`、`last_error=1`；
- `flush_queue` 只清 pending FIFO，不打断当前 active task；
- 若系统完全空闲且 pending 为空，再次 flush 会置位 `queue_underflow_sticky=1`、`last_error=2`；
- 这些 sticky 位都可以通过 `QUEUE_CMD[1]/[2]/[3]` 显式清除。

验证层面，这是当前 bonus 中验证最完整的一项之一。除了 baseline 的 4 个顶层寄存器/功能测试继续保留外，当前 Bonus 9 又新增了 3 个队列专项测试：

1. `test_task_fifo_status_transitions`：验证 empty → partial → full → overflow → clear 的状态迁移；
2. `test_task_fifo_desc_error_and_busy_flush`：验证非法 descriptor、busy 状态下 flush pending queue、idle flush underflow 等异常路径；
3. `test_task_fifo_four_task_chain`：验证 Host 显式连续提交 4 个任务后，系统自动 FIFO drain，且输出与计数器都正确。

在最新 0312 验证中，当前分支已明确通过两组配置：

- 默认 `FIFO_DEPTH=4`：`TESTS=7 PASS=7 FAIL=0`
- 参数化 `FIFO_DEPTH=8`：`TESTS=7 PASS=7 FAIL=0`

也就是说，当前任务队列已经不是“只能缓存当前+next 的深度 1 预取器”，而是符合题目 Bonus 9 语义的真正 multi-entry task FIFO。它仍然不是更重型的 descriptor-memory queue / doorbell / completion ring 体系，但按赛题定义，这已经足以视为 Bonus 9 的完整实现。

因此，对 Bonus 9 的正式结论应写成：**已完成，且当前最终状态为 parameterized true FIFO task queue；P1 ping-pong 原型只保留为历史演进背景。** 若后续继续增强，可再引入 descriptor-memory queue、driver-friendly completion 语义与更完整的软件协议，但这不影响当前的完成判定。

## 10. 逻辑综合与物理实现

本章内容沿用 [docs/report_0310/大纲.md](../report_0310/%E5%A4%A7%E7%BA%B2.md#10-%E9%80%BB%E8%BE%91%E7%BB%BC%E5%90%88%E4%B8%8E%E7%89%A9%E7%90%86%E5%AE%9E%E7%8E%B0) 的对应章节全文，不做改写。

## 11. 总结

本章内容沿用 [docs/report_0310/大纲.md](../report_0310/%E5%A4%A7%E7%BA%B2.md#11-%E6%80%BB%E7%BB%93) 的对应章节全文，不做改写。
