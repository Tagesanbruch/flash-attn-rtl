# 2026-03-19 mode15 K-smooth 实验报告（q8.8 cmodel）

## 1. 目标

在不改变 Baseline 方向（Q8.8 定点路线）的前提下，对 `mode15 (FIXED_Q8_IMPROVED)` 引入 SageAttention 启发的 `K-smooth`（按 token 维去均值）并验证：

1. 数值误差是否下降；
2. 端到端文本是否提升到可替换水平；
3. 若仍不足，提取关键数据定位后续方向。

---

## 2. 本次实现

分支：`exp/mode15-k-smooth`

代码改动：

- `inference/cmodel/bridge/fa_cmodel_bridge.cpp`
  - 新增环境开关：`FLASH_ATTN_CMODEL_K_SMOOTH=1`
  - 在 bridge 内对 `K` 执行去均值预处理（每个 head、每个 channel 在 token 维求均值后中心化）
  - 默认关闭，确保不影响既有路径

实现方式（定点实现）：

- 均值：`mean_d = round(sum_t K[t,d] / steps)`
- 中心化：`K'[t,d] = sat_s16(K[t,d] - mean_d)`

---

## 3. 实验设置

统一：`FLASH_ATTN_BACKEND=cmodel`, `FLASH_ATTN_CMODEL_MODE=15`

### 单样本（hello）A/B

- A: 无 K-smooth
- B: 开 K-smooth

### 5-prompt chat 回归

脚本：`scripts/run_cmodel_prompt_regression_chat.py`

- 对照1：mode15（无 K-smooth）
- 对照2：mode15 + K-smooth
- 对照3：mode15 + K-smooth + 既有 hotfix
- 参考：mode14（稳定参考）

并采集 real-diff：

- `inference/native/logs/realdiff_mode15_noks_5prompt.log`
- `inference/native/logs/realdiff_mode15_ksmooth_5prompt.log`

---

## 4. 关键结果

## 4.1 单样本（hello）

- 无 K-smooth：输出仍明显乱码/坍缩
- 开 K-smooth：输出恢复为 `Hello!`

说明：K-smooth 对 mode15 的端到端稳定性有显著正向作用。

## 4.2 5-prompt 文本对照

mode15（无 K-smooth）：

- 5/5 全部 `rc=0`，但文本基本不可读（乱码/坍缩）

mode15 + K-smooth：

- `hello`：`Hello!`
- `who are you`：`I'm Qwen, the AI assistant.`
- `write a short greeting`：`Hello! I'm Qwen, created by Alibaba Cloud.`
- `what is 1+1?`：可读但语义错误（答成身份句）
- 中文样本：仍明显异常

mode15 + K-smooth + hotfix：

- 与 mode15+K-smooth 基本一致（本轮样本未见额外收益）

mode14 参考：

- 英文样本语义明显更稳，`1+1` 正确输出 `2`

## 4.3 real-diff（5-prompt）

无 K-smooth：

- rows: `88032`
- max_abs_lsb: `2054`
- mean_abs: `46.5565`
- p99(desc): `894`
- p95(desc): `393`

开 K-smooth：

- rows: `75936`
- max_abs_lsb: `2594`（极少量离群更高）
- mean_abs: `19.633`（显著下降）
- p99(desc): `844`（下降）
- p95(desc): `1`（大幅下降）

解读：

- K-smooth 显著压低了“主流误差分布”（均值/p95），这与文本恢复可读的趋势一致；
- 但仍有少量极端离群（max_abs），导致语义稳定性尚未完全达标。

---

## 5. 结论

1. **成功点**：
   - K-smooth 在 mode15 上已证明有效，能从“普遍乱码”提升到“多数英文样本可读”。
   - 误差统计中，主流分布显著收敛（尤其 p95）。

2. **不足点（尚未达端到端可替换）**：
   - 仍存在少量高离群误差点（max_abs 级别）；
   - 在知识问答与中文样本上稳定性不足；
   - 相比 mode14，mode15 仍有明显语义差距。

3. **当前判定**：
   - `mode15 + K-smooth` 可视为有效前进，但**尚不足以直接替换 mode14 成为默认推理内核**。

---

## 6. 下一步建议（按收益排序）

P0（建议立即做）：

- 在 `mode15` 增加“阶段日志”开关，记录 `m/l/acc/norm` 的逐层逐位点偏移，优先盯 `layer23/head1` 离群点。

P1：

- 引入 dual-buffer 累加（short/long + flush 周期），对齐 SageAttention 的 inst-buffer 方法论，抑制少量离群传播。

P2：

- 将 K-smooth 从“全局开关”细化到“层/头可配”，与现有 hotfix 形成组合策略，进一步降低语义错误率。

---

## 7. 产物清单

- 代码：`inference/cmodel/bridge/fa_cmodel_bridge.cpp`
- 回归摘要：
  - `inference/native/logs/cmodel_prompt_regression_chat_summary_mode15_noks.txt`
  - `inference/native/logs/cmodel_prompt_regression_chat_summary_mode15_ksmooth.txt`
  - `inference/native/logs/cmodel_prompt_regression_chat_summary_mode15_ksmooth_hotfix.txt`
  - `inference/native/logs/cmodel_prompt_regression_chat_summary_mode14_ref.txt`
- real-diff：
  - `inference/native/logs/realdiff_mode15_noks_5prompt.log`
  - `inference/native/logs/realdiff_mode15_ksmooth_5prompt.log`

---

## 8. 追加实验：dual-buffer 定点模式（mode16）

在你选择“继续：做 dual-buffer 累加”后，新增独立模式：

- `Mode::FIXED_Q8_DUALBUF`（mode=16）
- 文件：
   - `cmodel/csrc/attention_core.hpp`
   - `cmodel/csrc/attention_kernels.cpp`
   - `inference/cmodel/bridge/fa_cmodel_bridge.cpp`（mode id 映射）
   - `inference/cmodel/bridge/cmodel_mode_sweep.cpp`（加入 mode16）

实现思路：

- 将 K 维 token 计算划分为固定 chunk（当前 16）；
- 每个 chunk 内做局部 online-softmax（`m_local/l_local/acc_local`）；
- chunk 结束后按 online-softmax 合并公式并入全局状态（`m_global/l_global/acc_global`）。

这相当于“局部短程 + 全局长程”的双层状态合并，目标是降低长链累计漂移。

### mode16 + K-smooth 结果（5 prompt）

- 英文样本：与 `mode15 + K-smooth` 基本同级，仍有可读提升；
- `what is 1+1?` 仍语义错误（未恢复为稳定数学回答）；
- 中文样本仍异常；
- 尚未达到替换 `mode14` 的稳定性标准。

结论：

- dual-buffer 方向在当前实现下**未带来决定性质量跃迁**；
- 主要收益仍来自 `K-smooth`；
- 下一步更应优先进入“分阶段日志（m/l/acc/norm）”定位离群传播点，再对 dual-buffer 做参数化（chunk、merge rounding、局部位宽）优化。

---

## 9. 追加落地：阶段日志定位（m/l/acc）

根据后续选择，已在 bridge 增加可过滤的阶段日志：

- 开关：`FLASH_ATTN_CMODEL_STAGE_TRACE=1`
- 过滤：
   - `FLASH_ATTN_CMODEL_STAGE_TRACE_MODE`
   - `FLASH_ATTN_CMODEL_STAGE_TRACE_LAYER`
   - `FLASH_ATTN_CMODEL_STAGE_TRACE_HEAD`
   - `FLASH_ATTN_CMODEL_STAGE_TRACE_POS`
- 输出：`FLASH_ATTN_CMODEL_STAGE_TRACE_FILE`

并扩展 bridge 上下文参数（layer/head）用于精准命中单个位点。

### 实测样本

- 目标位点：`mode15 + K-smooth`, `layer=23`, `head=1`, `pos=30`
- 日志：`inference/native/logs/cmodel_stage_trace_mode15_l23h1p30.log`

关键观察：

1. 在该位点中后段出现明显 `m` 跃迁（例如末段由 `m=1556` 跳到 `m=3655`）；
2. 跃迁后 `exp_old` 急剧减小，`l` 出现尺度突变（接近“重归一化”）；
3. `acc_abs_max` 在中段上升、末段回落，呈现“先扩张后压缩”的不稳定轨迹。

这与“少量离群点主导语义偏移”的现象一致，说明下一步优先级应是：

- 对 `m` 跃迁敏感段做更稳健的 merge/rounding；
- 在 dual-buffer 合并点增加可配置 rounding 与位宽；
- 对 `layer23/head1` 继续做细化 A/B。

---

## 10. 多 Prompt 扩展回归（按要求补充）

为收口当前阶段，补做了“普通 chat + role 格式”两类回归。

### 10.1 普通 chat（5 prompt）

- `mode15 + K-smooth` 与 `mode16 + K-smooth` 均较无 K-smooth 明显提升；
- 两者在英文短问答上可读性接近；
- 但在知识问答（`1+1`）与中文样本上仍存在语义稳定性问题。

日志：

- `inference/native/logs/cmodel_prompt_regression_chat_summary_mode15_ksmooth.txt`
- `inference/native/logs/cmodel_prompt_regression_chat_summary_mode16_ksmooth.txt`
- 参考：`inference/native/logs/cmodel_prompt_regression_chat_summary_mode14_ref.txt`

### 10.2 role 格式（system/user/assistant）

结果（mode15/mode16 + K-smooth）显示：

- role 输入下 cmodel 仍明显劣于 sw 参考，存在模板重复/结构化 token 异常；
- 说明“chat 可读提升”尚不能外推到“复杂 prompt 结构稳定替换”。

日志：

- `inference/native/logs/role_prompt_compare_summary_mode15_ksmooth.txt`
- `inference/native/logs/role_prompt_compare_summary_mode16_ksmooth.txt`

### 10.3 当前问题清单（阶段收口）

1. 主流误差分布虽下降，但仍有少量极端离群；
2. role 格式稳定性不足，提示离群传播仍会触发分布坍缩；
3. dual-buffer 当前实现还未压住“末段 m 跃迁导致的归一化尺度突变”。
