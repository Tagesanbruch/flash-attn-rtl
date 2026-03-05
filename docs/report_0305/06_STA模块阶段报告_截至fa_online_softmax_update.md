# STA 模块阶段报告（截至 `fa_online_softmax_update`）

## 1. 本次执行范围与停止点

按本轮要求，STA 只推进到 `fa_online_softmax_update` 为止，**后续模块与 top 级未开始**。

已完成的 `syn/*_20260305` 模块：
- `fa_clip_signed`
- `fa_mul_sat_q8_8`
- `fa_exp_pwl_8seg_q1_15`
- `fa_recip_nr_q16_16`
- `fa_online_softmax_update`

未开始（本轮刻意不跑）：
- `fa_row_reduction_core`
- `fa_axi_lite_regs`
- `fa_core_controller`
- `fa_attention_ip_top`（top）

## 2. 本轮报错与修复

### 2.1 原始报错
在 `fa_online_softmax_update` 的首轮日志中出现：
- `The output port o_m_q8_8_[3..7]_ is not constrained`

对应路径：
- `syn/fa_online_softmax_update_20260305/fa_online_softmax_update-500MHz/sta.log`（旧结果）

### 2.2 根因
`syn/sdc/default_clocked.sdc` 原始内容仅有 `create_clock`，未给 clocked 模块提供 I/O delay 约束，导致部分 output endpoint 被 STA 判定为 unconstrained。

### 2.3 修复动作
已更新 `syn/sdc/default_clocked.sdc`：
- 增加 `set_input_delay`
- 增加 `set_output_delay`
- 增加 `set_input_transition`

并做了 iEDA 兼容化处理：
- 去除 iEDA 不支持的 `remove_from_collection` / `sizeof_collection` 语法
- 改为 `[all_inputs]` / `[all_outputs]` 直接约束

### 2.4 修复后复跑结果
重新执行：
- `make sta-module STA_MODULE=fa_online_softmax_update STA_DATE=20260305 STA_CLK_FREQ_MHZ=500`

修复后日志结论：
- `timing engine run success`
- `unconstrained` 报错计数为 0

最新日志路径：
- `syn/fa_online_softmax_update_20260305/fa_online_softmax_update-500MHz/sta.log`

## 3. 关键 STA 结果（本轮截至点）

### 3.1 `fa_online_softmax_update`（500MHz 目标）
从最新 `sta.log` 提取：
- Worst endpoint（max）：
  - `o_acc_q16_16[25]_reg_p:D`
  - Path Delay: `5.016ns`
  - Required: `1.952ns`
  - **Slack (WNS): `-3.063ns`**
- 汇总（TNS）：
  - `core_clock max TNS = -337.970ns`
  - `core_clock min TNS = 0.000ns`

说明：
- 约束修复后，报告从“有 unconstrained 端点”变为“约束完整可比较”；
- 该模块在 500MHz 约束下 setup 违例明显，后续需要在结构/流水线层面优化。

## 4. 其他已跑模块状态（截至当前）

按 `sta.log` 自动统计：
- `fa_clip_signed`：`success=1`，`unconstrained=0`，`neg_slack_events=0`
- `fa_mul_sat_q8_8`：`success=1`，`unconstrained=0`，`neg_slack_events=4`
- `fa_exp_pwl_8seg_q1_15`：`success=1`，`unconstrained=0`，`neg_slack_events=3`
- `fa_recip_nr_q16_16`：`success=1`，`unconstrained=0`，`neg_slack_events=5`
- `fa_online_softmax_update`：`success=1`，`unconstrained=0`，`neg_slack_events=13`

备注：
- `neg_slack_events` 为日志中 “has negative slack” 事件计数，表示该约束下存在时序违规路径，不代表流程失败。
- 本轮重点是先完成到 `fa_online_softmax_update` 的可用 STA 与约束修复闭环；更深入路径分析和优化建议放在下一轮（继续模块与 top 级时统一整理）。

## 5. 下一步（待你确认后执行）

1. 从 `fa_row_reduction_core` 继续逐模块 STA（保持当前修复后的 SDC 模板）
2. 汇总完整模块级报告（含每模块 WNS/TNS 和关键违例路径）
3. 最后单独跑 top：`fa_attention_ip_top`，生成整体时序结论与优化优先级