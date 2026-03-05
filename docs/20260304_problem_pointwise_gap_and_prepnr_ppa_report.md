# 20260304 基于 problem.md 的逐点对照与 pre-P&R PPA 报告

## 0. 报告目的与证据导航

本文按 `problem.md` 原文要求逐条检查当前实现状态，给出：

- 是否满足（已完成 / 部分完成 / 未完成）
- 对应 RTL 代码位置
- 对应验证或结果文件位置
- 差距与下一步建议

### 0.1 本轮核心结果摘要

- 最新 RTL 端到端周期：`236,288`（满足 `<300k`）
- 精度：`MAE=0.000971925`、`MaxAE=0.00203197`（满足门限）
- Row2 并行已落地（compute 双行并行）
- 已补充模块级 Yosys synth/STA（pre-P&R）结果汇总

关键数据文件：

- `docs/data/20260304_rtl_summary.csv`
- `docs/data/20260304_rtl_latency_breakdown.csv`
- `docs/data/20260304_rtl_compute_breakdown.csv`
- `docs/data/20260304_sta_module_summary.csv`

---

## 1. 与 problem.md 的逐点对照（Baseline 必选）

> 原文来源：`problem.md`

## 1.1 2.1(1) 算法定义（SDPA目标）

### 判断：**已完成（定点近似实现）**

- score 计算（点积 + scale + causal mask）已实现：
  - `rtl/core/fa_attention_core.sv` 中点积与score：
    - `dp_partial_sum*`：行列点积分块累加
    - `dp_to_q8_8_*`：缩放前后路径
    - `i_causal_en` 条件mask
- online softmax 与加权累加已实现：
  - 维护 `row_m/row_l/row_acc`
  - 在 `C_SOFTMAX_PREP` 中更新 `m/l/acc`
- 最终归一化 `O = acc / l`：
  - `S_NORMALIZE` 中逐lane做除法并饱和到Q8.8

证据位置：

- `rtl/core/fa_attention_core.sv`（`score/softmax/normalize` 主路径）
- `dv/cocotb/tests/test_fa_attention_core.py`（`python_flash_attention` 参考实现）

---

## 1.2 2.1(2) FlashAttention-style 约束

### (a) 禁止显式存储注意力矩阵（SxS）

判断：**已完成**

- 设计中仅有 tile buffer（`q_buf/k_buf/v_buf`）与 per-row context（`row_m/row_l/row_acc`），无 `score[S][S]`/`P[S][S]` 存储结构。

证据位置：

- `rtl/core/fa_attention_core.sv`：
  - `q_buf[TQ][D]`, `k_buf[TK][D]`, `v_buf[TK][D]`
  - `row_m[TQ]`, `row_l[TQ]`, `row_acc[TQ][D]`

### (b) 必须 online softmax

判断：**已完成**

- `m/l/acc` 在每个 `score_ij` 到达时在线更新，无全量score回访。

证据位置：

- `rtl/core/fa_attention_core.sv`：`C_SOFTMAX_PREP` 中 `row_m/row_l/row_acc` 更新

### (c) 必须对 K/V 分块（tiling）

判断：**已完成**

- 使用 `TQ/TK`、`NUM_Q_TILES/NUM_K_TILES`，主状态机执行 `S_LOAD_K -> S_LOAD_V -> S_COMPUTE -> S_NEXT_K`。

证据位置：

- `rtl/core/fa_attention_core.sv`：`NUM_Q_TILES`, `NUM_K_TILES`, `S_LOAD_K`, `S_LOAD_V`, `S_NEXT_K`

---

## 1.3 2.1(3) 固定输入规模（S=256, d=64, batch=1, head=1）

### 判断：**已完成（默认值匹配）**

- RTL core 参数默认 `SEQ_LEN=256`, `D=64`。
- 当前验证与性能数据均在 `S=256,d=64` 口径下生成。

证据位置：

- `rtl/core/fa_attention_core.sv` 参数定义
- `dv/verilator_cpp/fa_attention_core_tb.cpp` 常量 `S=256`, `D=64`

备注：

- 实现允许参数化，但 baseline 默认与报告口径固定为赛题要求值。

---

## 1.4 2.1(4) 数据格式（Q8.8、中间位宽要求）

### 判断：**已完成**

- 输入/输出为 Q8.8（16-bit signed）。
- 点积累计使用 40-bit（`dp_acc0/dp_acc1`），满足“至少32-bit，建议40-bit”。
- online softmax 路径使用更高位宽（如 `row_l[31:0]`, `row_acc[63:0]`）。

证据位置：

- `rtl/core/fa_attention_core.sv` 中 `dp_acc*`, `row_l`, `row_acc` 声明与运算路径

---

## 1.5 2.1(5) 接口要求（AXI4-Lite + AXI4 Master DMA）

### 判断：**已完成**

- 顶层提供 AXI4-Lite 从接口用于寄存器配置。
- 顶层集成 AXI4 Master reader/writer DMA 通道。

证据位置：

- `rtl/top/fa_attention_ip_top.sv`：
  - AXI4-Lite 端口定义
  - AXI4 Master AR/R/AW/W/B 端口定义
  - `fa_dma_reader` / `fa_dma_writer` / `fa_axi_lite_regs` / `fa_attention_core` 集成

---

## 1.6 2.1(6) 寄存器映射（CTRL/STATUS/CFG/BASE/STRIDE/NEG_LARGE/SCALE/CYCLES）

### 判断：**已完成**

- 所有题面必需寄存器 offset 均实现：`0x00..0x40`。
- `STATUS` 含 busy/done/error；`CYCLES` 只读映射；`CTRL.START` 触发 start pulse。

证据位置：

- `rtl/bus/fa_axi_lite_regs.sv`：`REG_CTRL` 到 `REG_CYCLES` localparam
- `dv/cocotb/tests/test_fa_attention_ip_top_regs.py`：默认值、读写权限、启动与状态检查

---

## 1.7 2.1(7) 存储与资源约束

### 判断：**已完成（满足不存SxS）+ 部分说明待补强**

- 满足“禁止存储 score/p 全矩阵”。
- 使用 K/V tile + row context 路线。
- 当前并未将全量 K/V 常驻片上 SRAM（仅 tile 缓冲）。

证据位置：

- `rtl/core/fa_attention_core.sv` 缓冲结构

待补强：

- 题面还鼓励量化“若全量K/V上片的收益/代价”，当前报告中尚无完整面积-带宽量化对比实验。

---

## 1.8 2.1(8) 正确性验收（FP32误差门限）

### 判断：**已完成**

- 最新结果：
  - `rtl_fp32_mae = 0.000971925 <= 0.03`
  - `rtl_fp32_maxae = 0.00203197 <= 0.10`

证据位置：

- `docs/data/20260304_rtl_summary.csv`
- `docs/20260304_row2_rtl_alignment_and_latency_report.md`

---

## 1.9 2.1(9) 测试验证要求

### 判断：**部分完成**

题面要求包括：

1) AXI4-Lite 寄存器读写与启动完成流程
- 状态：**已完成**
- 证据：`dv/cocotb/tests/test_fa_attention_ip_top_regs.py`

2) 随机 Q/K/V 端到端验证
- 状态：**已完成**
- 证据：`dv/cocotb/tests/test_fa_attention_core.py`（随机输入 + golden 对比）

3) Causal mask corner case（如 i=0 行仅 j=0）
- 状态：**部分完成**
- 说明：实现支持 causal，测试含 causal 配置与路径，但缺少“i=0, j>0 强约束”的显式独立用例断言。

---

## 1.10 2.2(1) 主频目标（越高越好）

### 判断：**已进行 pre-P&R 估算（分模块）；顶层完整结果待补齐**

- 已完成分模块 500MHz 约束下 synth/sta。
- 部分关键模块出现 setup 负裕量（见第2节）。

---

## 1.11 2.2(2) 面积约束（<= 2M gates, 含存储折算）

### 判断：**部分完成（已有标准单元面积估算，尚未形成“等效门数+存储折算”闭环）**

- 当前可用数据主要来自 yosys/库面积（pre-P&R）与模块统计，尚未转换为赛事提交所需“统一口径等效门数（含存储折算）”。

---

## 1.12 2.2(3) 延迟指标（<300k cycles）

### 判断：**已完成**

- `total_cycles = 236,288 < 300,000`

证据位置：

- `docs/data/20260304_rtl_summary.csv`

---

## 1.13 2.2(4) 带宽目标（RD_BYTES/WR_BYTES统计与分析）

### 判断：**部分完成**

- DMA模块内已有 `rd_bytes/wr_bytes` 计数器（读写通道级）。
- 顶层已连出 `rd_bytes/wr_bytes` 内部信号，但目前未通过寄存器或统一报告导出。
- 当前可从 Verilator 统计近似换算（基于 beat 数）：
  - `rd_q=2048`, `rd_k=16384`, `rd_v=16383`, `wr_o=2048`（单位：beat，1 beat=16B）
  - 估算 `RD_BYTES ≈ (2048+16384+16383)*16 = 557,040 B`
  - 估算 `WR_BYTES ≈ 2048*16 = 32,768 B`

证据位置：

- `rtl/bus/fa_dma_reader.sv`, `rtl/bus/fa_dma_writer.sv`
- `rtl/top/fa_attention_ip_top.sv`
- `docs/data/20260304_rtl_summary.csv`

备注：

- 该换算是 testbench 口径估算，建议后续把 `rd_bytes/wr_bytes` 直接纳入报告CSV，避免统计偏差。

---

## 2. 分模块 pre-P&R PPA（Yosys synth/STA）

汇总文件：`docs/data/20260304_sta_module_summary.csv`

| 模块 | area(库面积) | inst | setup slack(min over max paths) | hold slack(min) | setup TNS |
|---|---:|---:|---:|---:|---:|
| fa_clip_signed | 58.52 | 28 | N/A | N/A | N/A |
| fa_mul_sat_q8_8 | 4469.36 | 2070 | N/A | N/A | N/A |
| fa_exp_pwl_8seg_q1_15 | 1892.52 | 946 | N/A | N/A | N/A |
| fa_recip_nr_q16_16 | 15454.04 | N/A | N/A | N/A | N/A |
| fa_online_softmax_update | 22663.20 | 11241 | -2.729 | 0.148 | -296.315 |
| fa_row_reduction_core | 44388.40 | 21677 | -8.301 | 0.088 | -815.095 |
| fa_axi_lite_regs | 4399.64 | 885 | 1.483 | 0.100 | 0.0 |
| fa_core_controller | 531.16 | 180 | 1.437 | 0.143 | 0.0 |

说明：

1. 上表为 pre-P&R 综合+STA 快速估算，不等于最终后端签核结果。
2. 组合模块未建立完整时钟路径约束时，`slack/TNS` 可能为 N/A 或不可比。
3. 软最大相关模块（`fa_online_softmax_update`, `fa_row_reduction_core`）在 500MHz 下存在明显 setup 压力，是后续时序主瓶颈。

分模块结论：

- 控制寄存器/控制器模块在 500MHz 约束下余量较大。
- softmax/reduction 类模块是 pre-P&R 主时序风险点，符合当前架构认知。

---

## 3. Top 级综合/STA尝试状态

### 当前状态：**已尝试，首次失败（依赖列表不完整）**

- 通过 `make sta-module STA_MODULE=fa_attention_ip_top` 首次尝试 top 级时，报错为：
  - `fa_attention_ip_top` 引用了 `fa_attention_core`，但 `cfg/sta_modules.mk` 的 `STA_RTL_fa_attention_ip_top` 未包含该依赖及DMA依赖。
- 因此 top 级 netlist 未完成输出，暂无有效 top pre-P&R 时序/面积结果可记录。

补充：

- 本报告生成后已再次执行一次同命令复测，结果一致，仍因同一依赖缺失失败。
- 失败摘要已单独落盘：`docs/data/20260304_top_sta_attempt_summary.txt`

建议修复路径（不影响当前baseline功能）：

- 在 `cfg/sta_modules.mk` 的 `STA_RTL_fa_attention_ip_top` 增补：
  - `rtl/bus/fa_dma_reader.sv`
  - `rtl/bus/fa_dma_writer.sv`
  - `rtl/core/fa_attention_core.sv`
  - 以及其依赖 `fa_mul_sat_q8_8/fa_exp/fa_recip`

---

## 4. 与赛题提交口径的差距清单（精简）

1. **Causal corner case 单测仍需补强**（显式 i=0 行约束）
2. **RD_BYTES/WR_BYTES 需形成统一导出口径**（建议接入 summary CSV）
3. **Top 级 STA 依赖清单需补齐后重跑**
4. **面积口径需补齐“等效门数+存储折算”**（当前仅有库面积统计）

---

## 5. 本报告对应文件位置说明（便于审阅）

- 逐点需求判定：本文件第1节
- 模块级 pre-P&R 汇总：本文件第2节 + `docs/data/20260304_sta_module_summary.csv`
- 当前RTL周期/精度结果：
  - `docs/data/20260304_rtl_summary.csv`
  - `docs/20260304_row2_rtl_alignment_and_latency_report.md`
- 细粒度延迟图表：
  - `docs/report/20260304_rtl_latency_breakdown.png`
  - `docs/report/20260304_rtl_compute_breakdown.png`
  - `docs/report/20260304_rtl_cmodel_compute_compare.png`
