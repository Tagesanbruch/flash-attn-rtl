# 2026-03-12 Bonus #2 多 Head 调度优化评估

## 1. 背景

当前 `exp/bonus2-mha` 已完成第一阶段标准 MHA 最小实现：

- top 级顺序调度多个 head；
- `fa_attention_core` 仍保持单 head 不变；
- 通过 `NUM_HEADS` 与 `HEAD_STRIDE` 控制多 head 运行。

本轮进一步评估：

1. 是否值得做跨 head overlap；
2. 是否值得做更细粒度的多 head 调度；
3. 下一步优化应落在哪一层。

## 2. 现有实测数据

当前已测到的 top/IP 级 full-run 结果：

| heads | cycles | comp_launch | recip_req |
|------:|-------:|------------:|----------:|
| 1 | 85928 | 64 | 256 |
| 2 | 171856 | 128 | 512 |
| 4 | 343712 | 256 | 1024 |
| 8 | 687424 | 512 | 2048 |

可以直接看出：

- `cycles(head=N) = N * cycles(head=1)`
- `comp_launch(head=N) = N * comp_launch(head=1)`
- `recip_req(head=N) = N * recip_req(head=1)`

这说明当前实现的两个事实：

1. **多 head 调度本身几乎没有额外控制开销**；
2. 当前性能瓶颈完全仍在单 head core 内部，而不在 top 级 head 切换逻辑。

## 3. 这意味着什么

### 3.1 现在做“更细的 head 调度”收益很有限

因为当前结果已经近似完全线性放大，所以：

- top 级 `head_done -> next_head_start` 的控制气泡几乎可以忽略；
- 继续优化 top 级微小切换周期，基本不会带来可见总周期改善。

也就是说：

> 当前不是“head 调度太粗”，而是“单 head core 本身成本占绝对主导”。

### 3.2 现在做“跨 head overlap”也不自然

跨 head overlap 真正要成立，通常至少需要以下条件之一：

1. head 间存在可复用数据；
2. 有独立 DMA / compute 通道，可把下一个 head 的预取和当前 head 的计算并行化；
3. core 内部已经把 load / compute / writeback 拆成更可组合的阶段。

但当前实现里：

- 每个 head 的 `Q/K/V/O` 地址空间彼此独立；
- `fa_attention_core` 自己封装了 DMA + tile loop + compute + writeback；
- top 级只能把整个 head 当作一个“大任务”来串行启动。

因此，如果不重构 core 边界，所谓“跨 head overlap”基本只能做到：

- 在两个 head 之间减少极小的空泡；

而这部分从现有线性结果看，已经几乎没有肉眼可见空间。

## 4. 真正值得做的优化层级

如果下一步真要继续优化多 head，优先级更合理的是下面两类。

### 4.1 方案 A：保持当前 top 调度不变，暂不做跨 head overlap

这是当前最推荐的结论：

- 保留现在的顺序 MHA 版本作为 Bonus #2 第一阶段稳定实现；
- 继续补更多验证覆盖；
- 不急于为了“看起来更高级”而做收益不明显的跨 head 调度重构。

### 4.2 方案 B：若必须继续提速，应下沉到 core 分层重构

如果后续一定要做多 head 性能优化，更合理的方向不是 top 级微调，而是：

1. **把 head loop 下沉到 core 内部**
   - 让 core 知道当前正在处理哪个 head；
   - 为后续更粗粒度 overlap 创造条件；
2. **拆开 DMA front-end 与 compute engine**
   - 让 next-head 的 `Q` 预取有机会和 current-head 的末尾阶段并行；
3. **增加双 Q-buffer / head context buffer**
   - 否则 next-head 预取会直接和 current-head 的本地状态冲突。

这已经不是“小修小补”，而是一次明确的微结构重构。

## 5. 当前建议

基于现有测量结果，当前建议是：

> **先不做跨 head overlap 的 RTL 重构。**

原因：

1. 当前 top 级多 head 调度已经几乎零额外开销；
2. 想继续提速，必须改动 core 内部边界；
3. 这类改动的风险和验证成本，明显高于当前可能获得的短期收益。

因此更合理的下一步顺序是：

1. 先把 `head=4/8` 的更多覆盖补齐；
2. 再决定是否要进入“core 内部 head-aware 重构”；
3. 若进入重构，应把它明确当作 Bonus #2 第二阶段，而不是当前最小实现的小补丁。
