# STA 模块阶段报告（0305 全模块汇总）

> 2026-03-06 补充说明：本文件反映的是 03-05 时点的模块 STA 基线。其后 `fa_recip_nr_q16_16` 已完成 10 级流水优化并在实验中达到 500MHz 收敛，相关最新解释请结合 [docs/report_0305/08_20260306流水线RTL落地与约束补充说明.md](docs/report_0305/08_20260306流水线RTL落地与约束补充说明.md) 与 [docs/20260306_pipeline_optimization_report.md](docs/20260306_pipeline_optimization_report.md) 一并阅读。

## 1. 执行范围

PDK：**ic**（`ics55_LLSC_H7CL_typ_tt_1p2_25_nldm`）

已完成 STA 的 `syn/*_20260305` 全部 8 个模块：

| # | 模块 | 时钟 | 目标频率 |
|---|------|------|----------|
| 1 | `fa_clip_signed` | vclk | 500 MHz |
| 2 | `fa_mul_sat_q8_8` | vclk | 500 MHz |
| 3 | `fa_exp_pwl_8seg_q1_15` | vclk | 500 MHz |
| 4 | `fa_recip_nr_q16_16` | vclk | 500 MHz |
| 5 | `fa_online_softmax_update` | core_clock | 500 MHz |
| 6 | `fa_row_reduction_core` | core_clock | 500 MHz |
| 7 | `fa_axi_lite_regs` | core_clock | 500 MHz |
| 8 | `fa_core_controller` | core_clock | 500 MHz |

未跑：`fa_attention_ip_top`（top 级）。

## 2. 本轮报错与修复

### 2.1 原始报错
`fa_online_softmax_update` 首轮日志出现 `The output port o_m_q8_8_[3..7]_ is not constrained`。

### 2.2 根因
`syn/sdc/default_clocked.sdc` 仅有 `create_clock`，未提供 I/O delay 约束。

### 2.3 修复
更新 `default_clocked.sdc`：增加 `set_input_delay` / `set_output_delay` / `set_input_transition`，去除 iEDA 不支持语法，改用 `[all_inputs]` / `[all_outputs]` 直接约束。修复后所有模块 `unconstrained=0`。

## 3. 全模块 STA 汇总（max delay / setup）

| 模块 | 面积(μm²) | WNS(ns) | TNS(ns) | Fmax(MHz) | 时序 |
|------|-----------|---------|---------|-----------|------|
| `fa_clip_signed` | 58.52 | **+1.346** | 0.000 | 1529.955 | ✅ MET |
| `fa_mul_sat_q8_8` | 4469.36 | -0.313 | -9.447 | 432.317 | ❌ VIOL |
| `fa_exp_pwl_8seg_q1_15` | 1892.52 | -0.507 | -8.320 | 398.917 | ❌ VIOL |
| `fa_recip_nr_q16_16` | 15454.04 | -11.491 | -253.674 | 74.126 | ❌ VIOL |
| `fa_online_softmax_update` | 22663.20 | -3.063 | -337.970 | 197.493 | ❌ VIOL |
| `fa_row_reduction_core` | 44388.40 | -14.157 | -1769.398 | 61.892 | ❌ VIOL |
| `fa_axi_lite_regs` | 4399.64 | **+0.729** | 0.000 | 787.069 | ✅ MET |
| `fa_core_controller` | 531.16 | **+1.277** | 0.000 | 1383.080 | ✅ MET |

> **WNS** = Worst Negative Slack（最差单路径 slack），正值表示满足约束  
> **TNS** = Total Negative Slack（所有违例路径 slack 之和）  
> **Fmax** = STA 报告中最差路径对应的最大可达频率

### hold 时序（min delay）

所有 8 个模块 **min TNS = 0.000**，hold 无违例。

## 4. 关键违例路径分析

### 4.1 `fa_row_reduction_core` — 最严重（WNS = -14.157 ns）

| Endpoint | Path Delay | Required | Slack |
|----------|-----------|----------|-------|
| `o_row_out_q8_8_15_` | 15.757 ns | 1.600 ns | -14.157 |
| `o_row_out_q8_8_14_` | 15.726 ns | 1.600 ns | -14.126 |

- 关键路径为组合逻辑 output `o_row_out_q8_8[15:0]`，路径延迟高达 ~15.7 ns
- 共 16+ 条违例路径（neg_slack_events = 16），含 `acc_q16_16` / `l_q16_16` 寄存器和输出端口
- **需流水线切割或多周期约束**

### 4.2 `fa_recip_nr_q16_16` — 严重（WNS = -11.491 ns）

| Endpoint | Path Delay | Required | Slack |
|----------|-----------|----------|-------|
| `o_recip_q16_16_0_` | 13.291 ns | 1.800 ns | -11.491 |
| `o_recip_q16_16_1_` | 12.916 ns | 1.800 ns | -11.116 |

- 纯组合逻辑（Newton-Raphson 迭代），路径延迟 ~13.3 ns
- 共 5+ 条违例路径
- **需拆分迭代为多级流水线**

### 4.3 `fa_online_softmax_update` — 中等（WNS = -3.063 ns）

| Endpoint | Path Delay | Required | Slack |
|----------|-----------|----------|-------|
| `o_acc_q16_16[25]_reg_p:D` | 5.016 ns | 1.952 ns | -3.063 |
| `o_acc_q16_16[31]_reg_p:D` | 5.010 ns | 1.952 ns | -3.057 |

- 违例集中在 `o_acc_q16_16` 和 `o_l_q16_16` 寄存器（累加路径）
- 共 13 条违例路径

### 4.4 `fa_exp_pwl_8seg_q1_15` — 轻微（WNS = -0.507 ns）

- Worst endpoint: `o_exp_q1_15_12_`，Path Delay 2.307 ns
- 共 3 条违例路径，差距较小

### 4.5 `fa_mul_sat_q8_8` — 轻微（WNS = -0.313 ns）

- Worst endpoint: `o_y_q8_8_14_`，Path Delay 2.113 ns
- 共 4 条违例路径，差距很小

## 5. 模块状态总览

| 模块 | STA 状态 | unconstrained | neg_slack_events |
|------|---------|---------------|-----------------|
| `fa_clip_signed` | success | 0 | 0 |
| `fa_mul_sat_q8_8` | success | 0 | 4 |
| `fa_exp_pwl_8seg_q1_15` | success | 0 | 3 |
| `fa_recip_nr_q16_16` | success | 0 | 5 |
| `fa_online_softmax_update` | success | 0 | 13 |
| `fa_row_reduction_core` | success | 0 | 16 |
| `fa_axi_lite_regs` | success | 0 | 0 |
| `fa_core_controller` | success | 0 | 0 |

## 6. 优化优先级建议

1. **P0 — `fa_row_reduction_core`**：WNS -14.157 ns，必须流水线化
2. **P0 — `fa_recip_nr_q16_16`**：WNS -11.491 ns，需拆分 NR 迭代
3. **P1 — `fa_online_softmax_update`**：WNS -3.063 ns，累加路径需优化
4. **P2 — `fa_exp_pwl_8seg_q1_15`**：WNS -0.507 ns，小幅优化可解决
5. **P2 — `fa_mul_sat_q8_8`**：WNS -0.313 ns，接近收敛

## 7. 下一步

1. 跑 top 级 `fa_attention_ip_top` STA
2. 针对 P0 模块进行流水线结构调整
3. 全模块 + top 级完整时序收敛报告