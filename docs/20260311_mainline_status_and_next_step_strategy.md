# 2026-03-11 主线状态更新与下一步发展策略

## 1. 当前主线状态（以 `main` 为准）

截至 2026-03-11，仓库当前只有一条活动主线 `main`。该主线已经不再是 2026-03-10 早些时候的 `ctx` 恢复态，而是**完成了 QK tag 化流式回收、4-context batch 化 softmax 调度，以及 normalize 输入尺度修正**之后的版本。

当前应统一采用如下结果作为主线口径：

- 端到端顶层 full-run：`85928 cycles`
- `rtl vs fixed-q8.8`：`mae_lsb = 0`，`max_err_lsb = 0`
- `rtl vs fp32`：`MAE = 0.002499`，`MaxAE = 0.006583`
- `compute = 67584`
- `dp = 66560`
- `score = 32768`
- `softmax = 32768`

上述结果来自 [docs/20260310_current_cycle_perf_and_accuracy_analysis.md](docs/20260310_current_cycle_perf_and_accuracy_analysis.md) 第 12～13 节，以及当前顶层 cocotb full-run 回归。

## 2. 历史数字的正确解释

当前仓库中同时出现过三个关键周期数字：

1. `145584 cycles`
   - 含义：较早一版稳定 baseline 的历史结果；
   - 价值：证明项目很早就已经满足赛题 `<300k cycles` 的基本门槛。

2. `608296 cycles`
   - 含义：把 `exp_h + ctx/exp_d` 高频 leaf 接回主线、但尚未完成 system-level overlap 时的恢复态结果；
   - 价值：用于定位真正瓶颈已从 leaf 本体转移到 `fa_attention_core` 调度。

3. `85928 cycles`
   - 含义：当前 `main` 主线的最新实测结果；
   - 价值：说明当前主线已经同时完成：
     - 高吞吐流式 QK 回收；
     - `ctx` 多上下文交错调度；
     - 数值尺度对齐修正；
     - 精度与周期双闭环。

因此，在后续 README、报告正文、答辩材料和分支管理中，应把 `85928 cycles` 作为当前活动主线的唯一当前口径；而 `145584` 与 `608296` 应仅保留为**历史演进节点**。

## 3. 当前主线的结构性判断

### 3.1 已经完成闭环的部分

1. **功能闭环**
   - `fa_attention_ip_top`、`fa_attention_core`、AXI-Lite、DMA、perf counters 已全部联通；
   - 顶层 cocotb full-run 通过；
   - `rtl vs fixed-q8.8` 已经做到完全一致。

2. **周期闭环**
   - 当前 `85928 cycles` 已远低于赛题 baseline 的 `<300k cycles` 约束；
   - `compute = 67584` 说明 compute 主体已经从“串行等待型”转为“流式重叠型”。

3. **精度闭环**
   - `rtl vs fp32: MAE = 0.002499, MaxAE = 0.006583`，显著优于赛题门限；
   - 当前误差主导项已不再是 `exp2_approx()` 本身，而是此前已修正的 `acc -> normalize` 尺度对齐问题。

4. **leaf 级 PPA 基础**
   - `fa_online_softmax_ctx/exp_d`：约 `536.2MHz`
   - `fa_qk_dotprod_slice(exp_h)`：约 `442.5MHz`
   - `fa_recip_nr_q16_16(exp_c)`：约 `526.7MHz`
   - `fa_o_normalize_block(exp_d)`：约 `360.8MHz`

### 3.2 当前真正的短板

当前主线最主要的未完成项，已经不是 baseline 周期或精度，而是以下三类更高层次目标：

1. **bonus/扩展能力尚未工程化落地**
   - 更长序列
   - padding mask
   - multi-head
   - task queue / chained DMA

2. **top/core 直接综合与完整 PPA 仍未补齐**
   - 当前更多是 leaf 级 STA；
   - 尚缺面向当前 `main` 主线的更系统化 top-down PPA 更新。

3. **多精度 MAC 仍停留在调研与方案层**
   - 价值高；
   - 但并非当前最高 ROI 的主线任务。

## 4. 下一步优先级建议

## 第一优先级：冻结当前主线，保留可提交基线

建议立即把当前 `main` 主线作为一条稳定基线冻结，单独建立 `baseline` 分支。理由：

- 当前已经同时满足周期与精度；
- 继续直接在唯一活动线上试验 bonus 或多精度方案风险较高；
- 后续任何探索都应建立在“可随时回到当前可提交版本”的前提下。

## 第二优先级：单独开低风险 bonus 分支

比起继续深挖多精度 MAC，当前更建议优先开一个**低风险高展示度**的 bonus 分支，优先考虑：

1. `S=512` / 更长序列支持
2. `padding mask`
3. `multi-head`
4. `task queue / DMA queue`

这些方向共同特点是：

- 不需要立即推翻已有 datapath；
- 对当前 `main` 的周期闭环风险较小；
- 更容易用 cocotb 做端到端功能验证；
- 对赛题 bonus 展示价值高。

## 第三优先级：多精度 MAC 作为研究支线

多精度 MAC / mixed precision MAC 的建议顺序应为：

1. 先做 `standalone` MAC/FMA lane 原型；
2. 再做 `16b -> 2x8b` 定点 subword reuse；
3. 最后再考虑 block floating / FP mantissa tree reuse；
4. 不建议在当前阶段直接把 attention 全链路改造成统一多精度架构。

结论：

> 多精度 MAC 很重要，但**不应该抢在 bonus 低风险分支之前**。

## 5. 推荐的新分支实验主题

若只选一个下一步实验分支，建议主题为：

> **在稳定 baseline 之外，优先实现低风险 bonus：`padding mask + 更长序列参数化验证`。**

原因：

- 与当前主线结构兼容；
- 更能体现 IP 从 baseline 走向“可扩展产品化”的演进；
- 比起多精度 MAC，更容易短期形成可验证、可汇报、可对比的成果。

## 6. deep research 输入（供外部 agent 使用）

### 6.1 Bonus 优先级研究

请调研在 FlashAttention-style RTL IP 已经完成 baseline 周期/精度闭环后，下一步最值得优先落地的 bonus 功能。重点比较：`S=512`、`padding mask`、`multi-head`、`task queue / chained DMA`、`AXI4-Stream`、`mixed precision MAC`。请从 RTL 改动量、验证成本、PPA 风险、展示价值四个维度做排序，并给出最适合“先单独开支线实现”的 1~2 个方向。

### 6.2 S=512 / 有效长度支持研究

请调研在单 batch、单 head、Q8.8、在线 softmax、tile 化 FlashAttention RTL 中，如何以最小控制改动支持：
1. `SEQ_LEN` 从 `256` 扩展到 `512`；
2. 增加 `valid_len`/padding mask 支持；
3. 说明 query-side 与 key-side mask 在硬件上最合理的处理方式；
4. 说明对 DMA 命令数、tile 组织、row context 存储和 perf counters 的影响。

### 6.3 Multi-head / Task queue 研究

请调研在当前已有 AXI-Lite + AXI4 DMA + perf counter 的 attention IP 上，如何以最小侵入方式加入：
1. `multi-head` 外层循环支持；
2. `task queue` 或 shadow-register ping-pong 机制；
3. 对寄存器映射、地址步长、验证与软件驱动的影响；
4. 哪一种方式最适合比赛型工程先落地。

## 7. 一句话路线建议

当前主线已经足以作为 baseline 冻结。接下来最合理的路线不是继续在主线直接冒险，而是：

1. **冻结当前 `main` 为 `baseline`；**
2. **新开低风险 bonus 分支；**
3. **把多精度 MAC 放到并行研究支线，而不是当前第一优先级。**
