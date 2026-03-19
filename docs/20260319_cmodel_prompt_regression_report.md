# 2026-03-19 cmodel 修复后多 Prompt 回归报告

## 1. 目的

在 `cmodel` 修复（默认 `mode=14`）后，验证：

1) 端到端可读性是否恢复；
2) 在 `system/user/assistant` 结构输入下，`cmodel` 与 `sw` 是否对齐；
3) 速度是否保持可用。

## 2. 回归数据源

- 常规 chat 模板回归：`inference/native/logs/cmodel_prompt_regression_chat_summary.txt`
- role 格式双后端对照：`inference/native/logs/role_prompt_compare_summary.txt`
- simple prompt 对照（调试用途）：`inference/native/logs/cmodel_prompt_regression_summary.txt`

## 3. 结果摘要

### 3.1 常规 chat 模板（推荐口径）

5 条样本均 `rc=0`，回答可读且语义基本正常：

- `hello` -> `Hello! How can I assist you today?`
- `who are you` -> `I am Qwen, a large language model...`
- `what is 1+1?` -> `1+1 equals 2.`

吞吐区间（本次样本）：

- prefill: `~11.1` 到 `~30.0 tok/s`
- decode: `~10.0` 到 `~20.8 tok/s`

### 3.2 role 输入（system/user/assistant）

对 3 条 role prompt 同时跑 `sw` 与 `cmodel`：

- 全部 `rc=0`；
- 文本主干一致（英文样本一致，中文样本也表现一致）。

结论：

- 在用户指定的 role 输入格式下，`cmodel` 与 `sw` 已对齐到可接受水平。

### 3.3 simple prompt（仅调试）

- 若关闭 chat 模板并直接裸 prompt（`RUN_FA_SIMPLE_PROMPT=1`），可读性不稳定；
- 该行为与此前观察一致，说明它更适合作为快速定位而非最终质量口径。

## 4. 判定

本轮“修复 cmodel infer 并做多 prompt 验证”任务通过：

- 端到端恢复可读输出；
- role prompt 对照通过；
- 性能保持显著快于 DPI 仿真路径。

## 5. 下一步建议

1) 基于 `mode=14` 固化 cmodel 基线（扩展到 20~50 prompt 自动回归）；
2) 以 cmodel 基线反推 RTL：优先对 `online_softmax_ctx` 与 `o_normalize` 的位宽/舍入策略做分步对齐。
