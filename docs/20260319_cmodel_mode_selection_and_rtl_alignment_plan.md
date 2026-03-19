# 2026-03-19 cmodel 模式选择含义、online-softmax 数据流对齐分析与 RTL 改造方案

## 1) 本轮结论摘要

- 已确认：`cmodel` 在原默认模式下会导致 infer 可读性异常（早期版本表现为乱码/模式坍缩）。
- 已修复：在 `cmodel` 内核新增 `Mode::FA_CORE_COMPAT`（mode=14），并设为 `run_fa_cmodel` 默认模式。
- 实测效果：`FLASH_ATTN_BACKEND=cmodel` 在 `hello`、decode=16 下恢复为可读句子：
  - `, how are you? I'm fine, thank you. How about you?`
- 多组回归（含 `system/user/assistant` 格式）显示 `cmodel` 与 `sw` 文本主干一致，具备下一步 RTL 对齐基线价值。

---

## 2) 模式选择含义（为什么选 mode=14）

`cmodel/csrc/attention_kernels.cpp::online_rtl_like` 当前存在多种语义路径：

- `mode=0 (RTL_STRICT)`：严格固定点风格，`exp` 与归一化均按硬件近似/定点更新。
- `mode=1~5`：不同 exp 近似与累加策略组合（ctx_step/interp/pwl/realexp）。
- `mode=10~13`：更高精度混合路径（float 累加或 hiacc 固定点），在随机张量上显著优于 `mode=0`。
- `mode=14 (FA_CORE_COMPAT, 本次新增)`：
  - 在线 softmax 更新与当前可用参考 `fa_core` 同语义；
  - 使用 `float` 域更新 `m/l/acc`，最终 Q8.8 量化输出；
  - 保留 causal/hard-mask 接口语义。

在本轮 sweep 中（`inference/cmodel/bridge/cmodel_mode_sweep.cpp`）：

- `mode=11/13/14` 都能收敛到 `max_abs_lsb=1` 量级；
- `mode=14` 的 `mae_lsb` 最低（本次数据下最佳），因此设为默认。

---

## 3) 数据流是否符合 online-softmax RTL 思路

### 3.1 RTL 现有主链路（模块级）

从 `rtl/core/fa_attention_core.sv`、`rtl/core/fa_online_softmax_ctx.sv`、`rtl/core/fa_o_normalize_block.sv` 看，核心链路为：

1. `QK dot`（分块并行累加，得到 score）
2. `m/l/acc` 在线更新（按 `m_new=max(score,m_old)`，再做 `exp_old/exp_new`）
3. `l_new = l_old*exp_old + exp_new`
4. `acc_new = acc_old*exp_old + exp_new*V`
5. 行尾 `reciprocal(l)` + `acc * recip` 归一化输出

即：RTL 架构思路本质上是标准 online softmax。

### 3.2 cmodel mode=14 对齐点

`mode=14` 在数学上也执行同一 online-softmax 递推（只是使用更高精度数值域）：

- 同样的 `m/l/acc` 状态变量；
- 同样的 causal/hard-mask 规则；
- 同样的“先递推后归一化”流程；
- 区别仅在于数值实现（float vs fixed approx）。

结论：

- **mode=14 与 RTL 在“数据流结构”上是一致的**；
- 目前差异主要在“数值逼近与位宽/舍入细节”，不是流程不一致。

---

## 4) 本轮定位到的关键误差来源

1. **cmodel 模式选择误配**：
   - 原默认模式过于近似，端到端推理可读性不稳定。

2. **桥接时序语义（已修正）**：
   - 单 query decode 场景需要显式映射到“当前 token 的因果位置”。

3. **近似链路累积误差**：
   - `exp` 近似、`reciprocal` 近似、acc/l 位宽截断，会在多层/多步中放大。

---

## 5) 下一步 RTL 对照修改方案（直接可执行）

目标：让 RTL 从“近似可用”向“与 mode=14 基线收敛”推进。

### 阶段A：建立一一对应观测点（先可测，再改）

- 在 RTL 或 DPI trace 中增加每行关键状态导出：
  - `score_q8_8, m_old, m_new, exp_old, exp_new, l_new, acc_new, recip`。
- 与 cmodel mode=14 同步导出相同字段，形成逐步对照表。

建议落点：

- `fa_online_softmax_ctx.sv`
- `fa_o_normalize_block.sv`

### 阶段B：先改最可能的高收益数值点

1. **`l/acc` 中间位宽与舍入策略**
   - 重点检查 `fa_online_softmax_ctx.sv` 中 `l_scaled/acc_scaled/pv_term` 的截断位切片，避免过早截断。

2. **归一化乘法路径舍入一致性**
   - 对齐 `fa_o_normalize_block.sv` 的 rounding（正负分支）与 cmodel 参考策略。

3. **exp 近似 LUT/插值精度**
   - 对 `exp2_approx` 的分段分辨率做局部提升（优先覆盖高敏区间）。

### 阶段C：回归门槛

- 随机张量一致性（head 级）：`max_abs_lsb <= 1` 占比 > 99%。
- 文本回归（role-prompt 三样本）：DPI 输出不出现 `/API` 坍缩。
- 性能回归：不明显降低现有队列吞吐。

---

## 6) 本轮新增/变更文件（与本主题直接相关）

- `cmodel/csrc/attention_core.hpp`（新增 `Mode::FA_CORE_COMPAT`）
- `cmodel/csrc/attention_kernels.cpp`（新增 mode=14 实现）
- `inference/cmodel/bridge/fa_cmodel_bridge.cpp`（mode 映射、decode 因果位置映射）
- `inference/native/flash_attn.c`（`FLASH_ATTN_BACKEND=cmodel` 默认 mode=14）
- `inference/cmodel/bridge/cmodel_mode_sweep.cpp`（模式扫频）
- `inference/native/logs/role_prompt_compare_summary.txt`（role prompt 对照结果）

---

## 7) 结论

- “先修 cmodel infer”目标已完成：通过 mode=14 内核修复，cmodel 可读性与稳定性显著提升。
- 从架构上看，cmodel 与 RTL 的 online-softmax 数据流是同构的；下一阶段应集中在 RTL 数值实现（位宽/舍入/近似）对齐。
- 建议立即进入“阶段A: 可观测化 + 对照表”，随后按阶段B顺序做最小改动收敛。

---

## 8) 关于“是不是全程 Q8.8”的明确说明

结论先说：**目前 native 的 `fa_core_q8_8` 不是“内部全 Q8.8 固定点”，而是“Q8.8 边界 + float 非线性核心”混合语义。**

证据（代码级）：

- 输入边界是 Q8.8：`flash_attention_forward` 先把 `q/k/v` 从 `float` 量化到 `q8_8_t`。
- 内部递推使用 float：`fa_core_q8_8` 中 `m_prev/l_prev/O_float/expf` 都是 float 域。
- 输出再量化为 Q8.8：`att_out[i] = float_to_q8_8(O_float[i])`。

所以你最早描述的链路可以更精确写成：

- `FP32 -> Q8.8 (边界)`
- `Q8.8 点积 + float 域 online-softmax 非线性/累加`
- `Q8.8 输出`
- `再回到 FP32`。

这也是为什么此前“native 能正常输出”，但“严格固定点近似模式”未必能直接保证端到端文本质量：

- 文本质量对累积误差极敏感；
- 非线性近似（exp/recip）与位宽截断会在层/步上放大。

---

## 9) “纯 Q8.8 fa core 核”尝试结果（本轮新增）

你要求的方向已实做验证：

- 在 cmodel 内核新增 `Mode::FIXED_Q8_IMPROVED`（mode=15）
- 特征：
   - 不使用 float 域递推；
   - `score/exp/l/acc/recip` 全按 fixed-point 路径更新；
   - 使用 `exp_real_q1_15 + recip_nr_rtl_q16_16 + 64bit acc`。

结果：

1) 随机张量对比（相对当前参考）：

- `mode=14`: `mae_lsb=0.622`, `max_abs_lsb=1`
- `mode=15`: `mae_lsb=1.136`, `max_abs_lsb=2`

2) 端到端推理（hello，decode=16）：

- `mode=15` 仍出现明显乱码/坍缩，未达到可用质量。

结论：

- “纯 fixed-point Q8.8”方向是可跑通的，但**当前实现仍不足以保证模型可读推理**；
- 现阶段可用基线仍是 `mode=14`，而 mode15 可作为后续 fixed-point 收敛分支继续优化（exp/recip/位宽/舍入）。

本轮进一步优化（新增）：

- 对 mode15 进行了两项改进：
   1) `m_prev` 初始化改为更接近负无穷（`-32768`）
   2) 归一化从 `recip_nr` 近似改为整数除法 `div_round_sat_s16(acc, l)`

改进后观测：

- 随机 sweep（含长序列 `seq=31/63`）中，mode15 已接近 mode14：
   - mode14: `mae_lsb=0.579`, `max_abs_lsb=1`
   - mode15: `mae_lsb=0.590`, `max_abs_lsb=2`
- 但端到端 chat（hello，decode=16）仍出现明显乱码，说明还有“模型分布相关”的误差放大点未覆盖。

---

## 10) 基于 problem.md 的合规性判定：float 内部组件是否符合 Baseline

结论（面向最终提交 RTL）：

- **不建议将 float 内部组件作为 Baseline 最终实现路径**。

依据：

1) 赛题 Baseline 明确“数据格式（定点）”：

- 输入 `Q/K/V`：Q8.8
- 输出 `O`：Q8.8
- 中间路径强调定点位宽设计（dot-product 至少 32-bit，softmax 允许更高位宽/分段缩放）

2) Baseline 目标是“可综合、低面积/低功耗”的 FlashAttention-style IP。

- 从工程实现与评测精神看，softmax/recip 的可解释 fixed-point 近似更符合验收口径；
- 浮点内核虽可在 C-model 中提高可读性，但作为 Baseline RTL 方案风险高（面积/功耗/实现偏离）。

因此建议：

- `mode14` 保留为“参考/对照模式”（用于验证链路与定位）；
- 交付导向应集中到纯 fixed-point 路线（例如 mode15 持续收敛），并将误差压入门限。

---

## 11) 真实推理张量差分（mode15 vs mode14）

已增加真实张量差分日志：

- 开关：`FLASH_ATTN_CMODEL_REAL_DIFF=1`
- 文件：`inference/native/logs/cmodel_real_diff.log`

采样场景：

- prompt=`hello`（chat 模板）
- `FLASH_ATTN_CMODEL_MODE=15`
- decode=16

统计摘要（15120 条）：

- 最大热点：`max_abs_lsb=2054`（layer=23, pos=40, head=1）
- position 平均误差热点：`pos=39/29/26/40/43...`
- layer 平均误差热点：`layer=11, 9, 3, 2, 16, 10...`

关键观察：

- mode15 与 mode14 的差异不是均匀噪声，而是在特定层位/位置显著放大；
- 与端到端乱码现象一致：中后段 token（较大 pos）更容易失真。

对下一步 fixed-point 收敛的直接指导：

1) 优先在热点层位（11/9/3/2）抓取 `l/acc` 演化，比较 mode14 与 mode15；
2) 重点检查长上下文位置（pos≈26~43）下的归一化动态范围；
3) 在 mode15 中增加可切换的局部策略（例如分段 scale、高位宽临时寄存）做 A/B。

---

## 12) 热点层局部修正实验（mode15）

已按热点层位执行局部修正 A/B：

- 策略：在 `mode15` 下，`layer in {2,3,9,11}` 且 `pos>=24` 时，局部切换到 fixed 模式 `mode13`。
- 开关：`FLASH_ATTN_CMODEL_MODE15_HOTFIX=1`
- 日志：`inference/native/logs/cmodel_mode15_hotfix.log`

观测：

- 热点层替换已大量命中（日志可见逐层逐头触发）；
- 但端到端 `hello/chat/decode16` 文本质量仍未恢复（仍有乱码/坍缩）。

结论：

- 当前失真并非仅由少数热点层可独立修复；
- 需要进入“更细粒度阶段日志”（m/l/acc/norm 逐阶段）来锁定真正的放大环节。
