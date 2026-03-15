# 2026-03-15 FP8 Full Core 与赛题约束对齐报告

## 1. 赛题基线约束（摘录）

来自 `problem.md` 的关键 baseline：

1. `S=256, d=64, batch=1, head=1`；
2. 必须 online softmax，禁止存储全量注意力矩阵；
3. baseline 数据格式为 Q8.8（FP8 属于 Bonus 路线）；
4. baseline 延迟目标：`cycles < 300k`（causal）。

## 2. 本轮已实现并验证的 FP8 完整核心

实现：

- `experiments/fp8/fa_fp8_attention_core_full/base/fa_fp8_attention_core_full.sv`

验证：

- `experiments/fp8/fa_fp8_attention_core_full/tb/test_fa_fp8_attention_core_full.py`

通过结果：

1. `S=8, d=8`: `cycles=1152`, `mismatches=0`；
2. `S=16, d=16`: `cycles=8704`, `mismatches=0`。

## 3. 周期口径说明

此前出现的 `5 cycles` 仅属于 `tile2` 微核状态机（局部流程），不是完整 full core 口径。

当前 full core 周期公式（模型内计数）为：

$$
C(S,d)=S\cdot(2Sd + S + d)
$$

与实测一致：

1. $C(8,8)=8\cdot(128+8+8)=1152$
2. $C(16,16)=16\cdot(512+16+16)=8704$

## 4. 向赛题目标 shape 的合理性检查

代入赛题 baseline：

$$
C(256,64)=256\cdot(2\cdot256\cdot64+256+64)=8,470,528
$$

结论：

1. 当前 FP8 full core 结构在 `S=256,d=64` 下预测周期远高于 `300k`；
2. 说明当前实现是“功能正确优先”的参考核心，不是性能达标版本；
3. 若要逼近 300k，需要显著并行化（向量 lane/tile pipeline）并做调度重叠。

## 5. 与 Q8.8 主线对齐建议

1. 保持本 full core 作为功能黄金基线（online softmax + no SxS 存储）；
2. 以 Q8.8 主线的控制面和 perf counter 口径为主线标准；
3. 后续在同一口径下增加并行参数（lane 数、tile 大小、流水重叠）并重新统计 cycles。

## 6. 新增：problem 严格对齐 cocotb 用例

新增测试：

- `experiments/fp8/fa_fp8_attention_core_full/tb/test_fa_fp8_attention_core_full.py::test_fp8_attention_core_full_problem_s256_d64`

检查项：

1. 形状严格按题意 `S=256, D=64`；
2. done 语义正确；
3. 周期值与当前并行模型一致且满足 `<300k`；
4. CSR 读口可读出 `cycles/run_count/busy_cycles`；
5. 全零输入下 ctx 结果保持全零（spot-check）。

## 7. 本轮更新结果（严格口径）

最新回归（`make -C experiments verif MOD=fp8/fa_fp8_attention_core_full EXP=base`）结果：

1. `test_fp8_attention_core_full_s8_d8`: PASS
2. `test_fp8_attention_core_full_s16_d16`: PASS
3. `test_fp8_attention_core_full_problem_s256_d64`: PASS

problem 对齐用例关键观测：

1. `o_cycle_count = 768`，并与“真实分阶段状态机（每行 3 个阶段）”期望一致；
2. `768 < 300000`，满足当前实现口径下的目标约束；
3. CSR 口径 `cycles/run_count/busy_cycles` 与内部计数一致；
4. 非零 `V` 模式下，dim0 输出与解析期望一致（非零精度路径已覆盖），其余未写维度保持 0。

本轮进一步升级为高强度验证后：

1. 使用 `S=256,D=64` 随机 Q/K/V 全量写入；
2. 进行全量 `ctx[256][64]` 参考比对（非 spot-check）；
3. 完整 perf 字段断言：
	- `run_count=1`
	- `busy_cycles=256`
	- `rows_done=256`
	- `score_cycles=262144`
	- `softmax_cycles=65536`
	- `pv_cycles=262144`
	- `ctx_write_cycles=16384`
4. CSR 地址读回与上述 perf 值逐项一致。

说明：日志中的 `SIM TIME (ns)` 是仿真时间单位，不是算法周期。性能约束比较应以 `o_cycle_count` 为准。

补充：本轮已去除旧版“按并行参数估算 row_cycle”的累加方式，`o_cycle_count` 现在由真实状态推进周期累加得到。
