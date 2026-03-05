# 20260305 Baseline P0 完成报告

## 1. 目标与完成状态

P0 定义的三个目标已全部完成并通过回归：

1. 控制路径压缩（减少状态切换空拍） ✅
2. K/V 双缓冲重叠原型（compute 期间预取下一 tile） ✅
3. 数值稳定性守护（在线 softmax 路径保护） ✅

---

## 2. 实施内容（怎么做的）

### 2.1 控制路径压缩

文件：`rtl/core/fa_attention_core.sv`

改动点：
- Compute 子 FSM 从
  - `C_IDLE -> C_DP_INIT -> C_DP_RUN -> C_SCORE_DONE -> C_SOFTMAX_PREP -> C_NEXT_KJ -> C_NEXT_QI -> C_DONE`
  压缩为
  - `C_IDLE -> C_DP_RUN -> C_SCORE_DONE -> C_SOFTMAX_PREP -> C_DONE`
- 将 `C_DP_INIT/C_NEXT_KJ/C_NEXT_QI` 的功能内联到 `C_IDLE/C_SOFTMAX_PREP`。
- 主状态机去掉单独 `S_NEXT_K`，在 `S_COMPUTE` 内直接决定进入下一个 tile 或 normalize。

效果：减少控制状态周转拍与主状态跳转拍。

### 2.2 K/V 双缓冲重叠原型

文件：`rtl/core/fa_attention_core.sv`

改动点：
- K/V buffer 从单 bank 改为 ping-pong：
  - `k_buf0/k_buf1`
  - `v_buf0/v_buf1`
- 新增 `active_bank`（计算使用）与 `pref_target_bank`（预取写入）。
- 新增预取状态机 `pf_state`：
  - `PF_IDLE -> PF_CMD_K -> PF_DATA_K -> PF_CMD_V -> PF_DATA_V -> PF_DONE`
- 在 `S_COMPUTE` 中并行执行：
  - 当前 bank 计算
  - 下一 K/V tile 的 DMA 预取
- 当前 tile compute 完成后：
  - 若 `pf_state == PF_DONE`，直接 bank 翻转并继续下一 tile compute
  - 不再回到 `S_LOAD_K/S_LOAD_V`

效果：将 K/V 装载与计算重叠，显著降低 `ms_other_cycles`。

### 2.3 数值稳定性守护

文件：`rtl/core/fa_attention_core.sv`

改动点：
- 在线 softmax 更新中的 `l_new` 增加最小值保护：
  - `l_new_safe = (l_new == 0) ? 1 : l_new`
- 写回 `row_l` 使用 `l_new_safe`，降低分母退化为 0 的风险。
- 保留 normalize 阶段 `den==0` 保护分支（原有逻辑）。

效果：在性能优化后保持误差与稳定性一致。

---

## 3. 数据与结果

## 3.1 对比基线（P0 前）

来源：`docs/20260304_row2_rtl_alignment_and_latency_report.md`
- `total_cycles = 236,288`
- `rtl_fp32_mae = 0.000971925`
- `rtl_fp32_maxae = 0.00203197`

## 3.2 中间版本（控制路径压缩后）

来源：本轮中间回归（同一统计文件路径）
- `total_cycles = 170,208`
- 误差保持不变并通过门限。

## 3.3 最终版本（P0 三项目标完成）

来源：`docs/data/20260304_rtl_summary.csv`
- `total_cycles = 145,584`
- `rtl_fp32_mae = 0.000971925`
- `rtl_fp32_maxae = 0.00203197`
- 门限检查：`MAE<=0.03` PASS，`MAX_AE<=0.10` PASS

相对 `236,288` 的降幅：
- 周期减少 `90,704`
- 降幅约 `38.39%`

---

## 4. 最新分解结果（关键）

来源：`docs/data/20260304_rtl_latency_breakdown.csv`

- `DMA_RD_Q = 2,048`
- `DMA_RD_K = 16,384`
- `DMA_RD_V = 16,383`
- `DMA_WR_O = 2,048`
- `Compute+Normalize+Ctrl = 108,721`

来源：`docs/data/20260304_rtl_compute_breakdown.csv`

- `Compute:DP = 98,304`
- `Compute:Score = 32,768`
- `Compute:Softmax+PV = 32`
- `Compute:Ctrl = 96`
- `Normalize = 2,056`

说明：
- 控制路径压缩后 `cs_ctrl_cycles` 已非常低。
- 双缓冲重叠主要体现在主状态其它开销下降（`ms_other_cycles` 收敛）。

---

## 5. 回归命令与通过情况

执行命令：

```bash
make rtl-latency-profile
make check-sdpa-verilator-cpp
```

结果：均通过。

产物更新：
- `docs/data/20260304_rtl_summary.csv`
- `docs/data/20260304_rtl_timeline.csv`
- `docs/data/20260304_rtl_latency_breakdown.csv`
- `docs/data/20260304_rtl_compute_breakdown.csv`
- `docs/report/20260304_rtl_latency_breakdown.png`
- `docs/report/20260304_rtl_compute_breakdown.png`

---

## 6. 关键报告（附）

- [工程总览与测试手册](../README.md)
- [P0 路线来源（论文映射与优先级）](20260305_architecture_next_steps_from_papers.md)
- [本报告：P0 完成总结](20260305_baseline_p0_completion_report.md)
- [前序 row2 对齐报告（P0 前参考基线）](20260304_row2_rtl_alignment_and_latency_report.md)

---

## 7. 结论

Baseline P0 三项目标均已落地，且在不牺牲精度门限的前提下，将总周期推进到 `145,584`，为后续 baseline 稳态收敛与 bonus 开发留出了充足余量。