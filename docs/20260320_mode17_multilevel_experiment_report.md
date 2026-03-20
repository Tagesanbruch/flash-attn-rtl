# 2026-03-20 多级实验测试报告（基于 SageAttention 映射路线）

## 1. 实验分级与配置

本轮按三层执行：

- **Level-1（算子级）**：`cmodel_mode_sweep` 随机张量误差扫描
- **Level-2（chat级）**：5 条 chat prompt 回归
- **Level-3（role级）**：3 条 `system/user/assistant` 结构化 prompt 回归

对比配置：

- `mode14`（参考稳态）
- `mode15 + K-smooth`
- `mode17 + K-smooth`（dual-buffer, chunk=8）
- `mode17 + K-smooth + multi-guard`

其中 multi-guard：

- layers=`2,3,9,11,23`
- heads=`1,8,9,10,11,12,13`
- pos_begin=`24`

---

## 2. Level-1：算子误差（随机张量）

来源：`inference/native/logs/cmodel_mode_sweep_20260320.log`

关键模式摘录：

- mode14: `mae_lsb=0.579468`, `max_abs_lsb=1`
- mode15: `mae_lsb=0.58964`, `max_abs_lsb=2`
- mode16: `mae_lsb=0.590007`, `max_abs_lsb=1`
- mode17: `mae_lsb=0.58846`, `max_abs_lsb=1`
- mode18: `mae_lsb=0.587321`, `max_abs_lsb=1`

观察：

- 在随机张量层面，`mode14/15/16/17/18` 都处于接近量级；
- `mode17/18` 相比 `mode15` 在 `max_abs` 上更稳（降到 1）；
- 这说明“端到端差异”主要不是简单随机误差可解释。

---

## 3. Level-2：chat 回归

来源：

- `inference/native/logs/cmodel_prompt_regression_chat_summary_mode14_20260320.txt`
- `inference/native/logs/cmodel_prompt_regression_chat_summary_mode15ks_20260320.txt`
- `inference/native/logs/cmodel_prompt_regression_chat_summary_mode17ks_20260320.txt`
- `inference/native/logs/cmodel_prompt_regression_chat_summary_mode17ks_guard_20260320.txt`

### 3.1 mode14（参考）

- `hello`：`Hello! How can I assist you today?`
- `who are you`：语义正确
- `what is 1+1?`：`1+1 equals 2.`（正确）
- 中文样本：可读（虽然是英文拒答句）

### 3.2 mode15 + K-smooth

- `hello`、`who are you`、`write a short greeting`：可读
- `what is 1+1?`：错误（答成身份句）
- 中文样本：乱码/结构异常

### 3.3 mode17 + K-smooth

- 英文短问答总体可读
- `what is 1+1?`：出现 `1+1...2`，**较 mode15 更接近正确**
- 中文样本：仍异常

### 3.4 mode17 + K-smooth + multi-guard

- 英文样本偏“模板化/重复化”增多（如 `I am Qwen...`, `Hello, Qwen...`）
- `what is 1+1?` 退化为身份句，未提升
- 中文样本仍异常

观察：

- chat 场景中，`mode17 + K-smooth` 相对是当前最优候选；
- multi-guard 没有带来稳定增益，且部分样本退化。

---

## 4. Level-3：role 回归

来源：

- `inference/native/logs/role_prompt_compare_summary_mode14_20260320.txt`
- `inference/native/logs/role_prompt_compare_summary_mode15ks_20260320.txt`
- `inference/native/logs/role_prompt_compare_summary_mode17ks_20260320.txt`
- `inference/native/logs/role_prompt_compare_summary_mode17ks_guard_20260320.txt`

### 4.1 mode14

- cmodel 与 sw 在 3 条 role prompt 上文本主干一致（可读且结构正常）

### 4.2 mode15ks / mode17ks / mode17ks_guard

- 三者都存在明显结构化异常：
  - role 标记重复（`system:...` / `User\nD:` 等）
  - token 片段拼接异常
  - 中文样本严重失真
- `mode17ks_guard` 的 decode 速度与输出稳定性未显著优于 `mode17ks`

观察：

- **role 是当前主要阻塞点**；
- 当前优化在 chat 上有效，但尚未跨过“结构化 prompt 稳定替换”门槛。

---

## 5. 总结结论

1. `mode17 + K-smooth` 仍是本轮最优候选（尤其相对 `mode15ks` 在 `1+1` 样本更接近正确）。
2. `multi-guard`（多热点回退）命中正常，但对端到端稳定性收益有限，且有退化样本。
3. `mode14` 在 role 结构上明显优于所有纯定点候选，当前仍不能直接替换。

---

## 6. 下一步建议（紧接着可执行）

- 进入 **merge 参数系统扫描 + logits 级对照** 联合实验：
  - 扫描：`chunk`、merge rounding、局部位宽
  - 对照：首发散 token 的 top-k/logit 偏移
- 目标：把“chat 可读”推进到“role 稳定”。

---

## 7. 本轮数据文件

- `inference/native/logs/cmodel_mode_sweep_20260320.log`
- `inference/native/logs/cmodel_prompt_regression_chat_summary_mode14_20260320.txt`
- `inference/native/logs/cmodel_prompt_regression_chat_summary_mode15ks_20260320.txt`
- `inference/native/logs/cmodel_prompt_regression_chat_summary_mode17ks_20260320.txt`
- `inference/native/logs/cmodel_prompt_regression_chat_summary_mode17ks_guard_20260320.txt`
- `inference/native/logs/role_prompt_compare_summary_mode14_20260320.txt`
- `inference/native/logs/role_prompt_compare_summary_mode15ks_20260320.txt`
- `inference/native/logs/role_prompt_compare_summary_mode17ks_20260320.txt`
- `inference/native/logs/role_prompt_compare_summary_mode17ks_guard_20260320.txt`
