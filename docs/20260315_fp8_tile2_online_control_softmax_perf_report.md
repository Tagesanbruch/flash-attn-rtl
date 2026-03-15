# 2026-03-15 FP8 Tile2 Online Softmax + 控制面 + Perf Counter 实现报告

## 1. 本轮目标

按最新要求完成以下实现并验证：

1. 寄存器控制面语义（start/busy/done）；
2. 完整状态机调度；
3. online softmax（max-sub + exp 近似 + 归一化）；
4. perf counter 计数；
5. 配套回归验证。

## 2. 实现模块

- `experiments/fp8/fa_fp8_attention_core_tile2_online/base/fa_fp8_attention_core_tile2_online.sv`

### 2.1 控制面/状态级

输入控制：

1. `i_cfg_start`
2. `i_cfg_round_mode`
3. `i_cfg_saturate_en`
4. `i_cfg_score_scale_q1_14`

状态输出：

1. `o_status_busy`
2. `o_status_done`

状态机：

1. `IDLE`
2. `SCORE0`
3. `SCORE1`
4. `SOFTMAX`
5. `CTX0`
6. `CTX1`
7. `DONE`

### 2.2 Online Softmax

在 `SOFTMAX` 状态执行：

1. `m = max(score0, score1)`
2. `e0 = exp2_approx(score0 - m)`
3. `e1 = exp2_approx(score1 - m)`
4. `w0 = e0 / (e0 + e1)`，`w1 = e1 / (e0 + e1)`（Q0.15）

边界处理：

1. `e_sum == 0` 时，`w0=w1=0.5`；
2. 归一化后权重做 `Q0.15` 上限钳位到 `32767`，避免 `32768` 符号翻转。

### 2.3 Perf Counter

新增计数输出：

1. `o_perf_cycles`
2. `o_perf_score_steps`
3. `o_perf_softmax_steps`
4. `o_perf_pv_steps`

当前 tile2 口径：

1. cycles = 5
2. score_steps = 2
3. softmax_steps = 1
4. pv_steps = 2

## 3. 验证

测试文件：

- `experiments/fp8/fa_fp8_attention_core_tile2_online/tb/test_fa_fp8_attention_core_tile2_online.py`

命令：

```bash
make -C experiments verif MOD=fp8/fa_fp8_attention_core_tile2_online EXP=base
```

结果：

- `samples=300`
- `mismatches=0`
- `ctx_mis=0`
- `done_mis=0`
- `perf_mis=0`

## 4. 调试与修复记录

### 4.1 初版失败

初版 `mismatches=291/300`，表现为：

1. `done` 与 perf 正常；
2. `ctx` 符号在部分样本翻转。

### 4.2 根因

online softmax 归一化后，权重在极端样本可能得到 `32768`，写入有符号 16 位后变成 `-32768`，导致 PV 累加方向错误。

### 4.3 修复

1. RTL 对 `w0/w1` 增加上限钳位 `32767`；
2. Python 参考模型同步钳位；
3. 复测后全 PASS。

## 5. 对齐说明（面向 Q8.8 主线）

本次版本已具备：

1. 清晰的 start/busy/done 控制语义；
2. 显式阶段化状态机（便于映射主线调度）；
3. perf counter 可观测口径（便于和 Q8.8 横向比较）。

仍待下一步完成：

1. 与顶层寄存器映射统一；
2. 与现有 `fa_attention_ip_top` 主线总线/数据搬运对接；
3. 在统一回归框架中做全核验证。
