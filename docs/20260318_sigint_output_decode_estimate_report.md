# 2026-03-18 SIGINT输出收敛与Decode阶段估算报告

## 1. 本轮工作内容

本轮围绕两个目标推进：

1) 修复手动 Ctrl+C 后“4条 diff-trace 之后出现大量乱码”的问题。  
2) 在中断路径下尽量保留与常规运行一致的统计文本（PROFILING RESULTS / OPERATION COUNTS）。

完成的代码改动：

- 在 `chat()` 主循环增加 SIGINT 检查，避免信号后继续采样与解码输出。  
- 在 `forward()` 返回后再次检查 SIGINT，避免使用不完整状态继续生成 token。  
- 中断后保留统计区块输出，并加除零保护，避免早停时统计打印异常。  

对应文件：

- `inference/native/run_fa.c`
- `inference/native/flash_attn.c`
- `inference/native/flash_attn.h`

---

## 2. 复现实验与结论

### 2.1 你指定方式复现

按你指定命令前台直跑、手动 Ctrl+C（未使用脚本自动发 SIGINT）：

`FLASH_ATTN_BACKEND=dpi FLASH_ATTN_DPI_DIFF_TRACE=1 FLASH_ATTN_DPI_DIFF_TRACE_FILE=/tmp/fa_diff_trace.log FLASH_ATTN_DPI_ASSERT_ON_DIFF=0 ./build/run_fa_dpi "hello"`

### 2.2 结果

- SIGINT 时仅输出最后 4 条 diff-trace（show_last=4）。
- 4 条 trace 后不再出现乱码。
- 中断后会打印：
  - achieved prefill tok/s
  - achieved decode tok/s
  - PROFILING RESULTS
  - OPERATION COUNTS

结论：你反馈的“4条后乱码”问题已在当前路径消失。

---

## 3. 问题(1)回答：是否走到 decode 输出 token 阶段

结论：**没有走到 decode 输出 token 阶段**。

依据：

- 中断后统计中 `Tokens : prefill=30, decode=0`，说明 decode 侧尚未产生 token 输出。  
- 终端输出中在 `Answer:` 后未出现正常 decode 文本 token（仅中断与摘要信息）。

---

## 4. 问题(1)补充：基于当前数据的时间估算

你要求“基于 DPI 运行时间 + 非 DPI run 数据估算”。这里给出一个工程估算区间。

### 4.1 非 DPI 实测参考（run_fa）

同 prompt=`hello` 实测：

- achieved prefill tok/s = 35.799522
- achieved decode tok/s = 37.974682

说明 SW 路径可在秒级完成 prefill 并进入 decode。

### 4.2 DPI 侧观测点

手动 Ctrl+C 的该次运行中，diff-trace summary 显示：

- total_mismatch = 270（等价于已完成 270 个 attention head-task 的比对记录）
- 该次统计 `time_attn ≈ 32.273s`

将其粗估为 task 吞吐：

- 约 270 / 32.273 ≈ 8.37 task/s

若按当前模型配置（24 层、14 heads）估算，每个 token attention 任务量约：

- 24 × 14 = 336 task/token

到达首个 decode 输出前，需要先完成约 30 个 prefill token：

- 任务总量约 30 × 336 = 10080 task
- 估算时长约 10080 / 8.37 ≈ 1204s ≈ 20 分钟

### 4.3 估算结论

- 以当前观测，DPI 到“首个 decode token 输出”大概率在**十几到二十多分钟量级**。  
- 与非 DPI（秒级）相比，量级差异很大。

### 4.4 误差说明

该估算是工程近似，误差来源包括：

- SIGINT 时刻不固定，采样窗口有限。  
- prefill 内不同 pos 的 attention 代价不完全恒定。  
- 主机负载和进程调度会影响 wall time。

---

## 5. +2 LSB 根因定位进展（本轮）

已运行 `inference/dpi/tests/dpi_minvec_compare`，结果：

- `max_abs_lsb=2` 稳定复现（seq_len=0 最小向量）。

该现象说明：即使在最小场景（单步 attention）也有系统偏差，问题更像是

- 归一化/量化语义差异（例如 reciprocal 近似、量化舍入方向、参考模型中的 1e-6 项），

而不是队列调度或长序列累积误差。

下一步建议按阶段拆分：

1) 固定 `seq_len=0` 做纯单步对照，分别切换参考量化策略（trunc / floor / nearest）。  
2) 在 DPI 侧加轻量 debug 导出（归一化前后、最终写回前）定位首个偏离点。  
3) 将该阶段结论回灌到 `flash_attn.c` 参考模型，确认是否语义对齐可消除 +2 LSB。

---

## 6. 当前状态小结

- SIGINT 输出行为：已收敛（最后4条 trace + 无乱码 + 统计文本保留）。  
- decode 阶段：本次手动中断未到达 decode token 输出。  
- 时间估算：DPI 首 decode 约十几至二十多分钟量级，SW 为秒级。  
- +2 LSB：已定位为“最小向量即可复现”的语义类问题，正在进入阶段化根因分解。
