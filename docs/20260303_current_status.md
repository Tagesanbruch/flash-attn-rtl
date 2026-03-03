# FlashAttention IP 当前工作总结（阶段性）

## 1. 项目定位

- 路线：借鉴 FSA 的微架构思想（执行计划、阵列融合），但不直接复用 chipyard/chisel 工程。
- 目标：以 SystemVerilog 实现赛题可提交 baseline（Q8.8、online softmax、tiling、causal、AXI-Lite+DMA模式）。
- 当前优先策略：16x16 小阵列/小核思路先打通（便于本机仿真与快速迭代）。

## 2. 已完成内容

### 2.1 规划与分析

- `plan.md` 已完成增强：
  - 明确“FSA 参考而非直接提交”；
  - 明确 baseline 与 bonus 分离策略；
  - 明确 16x16 优先落地路径；
  - 明确赛题寄存器映射对齐策略。
- 报告已补充：`report/fsa_2507_11331_analysis.md`，覆盖 FSA 从软件栈到硬件实现的逐层分析与赛题对照。

### 2.2 RTL 与接口

已实现模块：
- 原语/软算子：
  - `rtl/common/fa_mul_sat_q8_8.sv`
  - `rtl/softmax/fa_exp_pwl_8seg_q1_15.sv`
  - `rtl/softmax/fa_recip_nr_q16_16.sv`
  - `rtl/softmax/fa_online_softmax_update.sv`
- 中层/骨架：
  - `rtl/core/fa_row_reduction_core.sv`
  - `rtl/core/fa_core_controller.sv`
- 接口/顶层：
  - `rtl/bus/fa_axi_lite_regs.sv`
  - `rtl/top/fa_attention_ip_top.sv`

### 2.3 验证工程

- 已建立 cocotb 单模块回归：mul/exp/recip/online softmax。
- 已新增顶层寄存器流验证：
  - `dv/cocotb/tests/axilite_master.py`
  - `dv/cocotb/tests/test_fa_attention_ip_top_regs.py`
- 顶层测试已覆盖：
  - 寄存器读写；
  - START->BUSY->DONE 流程；
  - DONE 清零；
  - CYCLES 读回。

### 2.4 Python 对比路径

- 已提供定点参考与 Torch 对比：
  - `dv/python/ref_attention.py`
  - `dv/python/torch_compare.py`
- 当前对比结果（示例）在误差上显著优于赛题门限（MAE 与 MaxAE 均远小于 baseline 要求）。

### 2.5 工程化

- 已初始化 git 仓库。
- `.gitignore` 已配置，忽略 `ref/` 与 `useless/` 及仿真构建产物。
- 根 Makefile 已支持：`lint` / `test` / `regress` / `compare-torch`。

## 3. 当前状态评估

- **可运行性**：RTL lint 通过，核心 cocotb 回归可运行，顶层寄存器流程测试通过。
- **正确性基线**：Python 参考与 torch 对比趋势健康，误差余量较大。
- **缺口**：尚未完成完整 16x16 tile 计算核（QK^T+online softmax+PV）与真实 DMA 数据通路。

## 4. 下一步（建议）

1. 完成 16x16 中层计算核并接入 top（先 memory model，再 DMA 实链路）。
2. 扩展 cocotb：S=32 缩尺端到端，再到 S=256。
3. 增加 torch 对比回归：快速（S=64）+ 夜间（S=256，多 seed）。
4. 开始单模块/中层 yosys+iEDA STA 与面积对比。

## 5. 风险与关注点

- 定点位宽与近似误差在 S=256 时可能放大，需要多 seed 回归确认。
- 顶层接入 DMA 后，时序/握手复杂度显著提高，建议维持“控制先正确、吞吐后优化”的节奏。

## 6. STA 环境搭建（20260303）

### 6.1 已完成的环境与流程

- 已在根 `Makefile` 增加模块化 STA 入口，支持：
  - 单模块独立综合/STA；
  - 输出目录按 `syn/模块名_日期` 命名（例如 `syn/fa_core_controller_20260303`）；
  - 自动适配 `yosys-sta` 的 Docker wrapper 路径映射。
- 新增模块依赖映射：`cfg/sta_modules.mk`。
- 新增 SDC：
  - `syn/sdc/default_clocked.sdc`（时序模块，默认 `clk`）；
  - `syn/sdc/default_comb.sdc`（组合模块，最小约束）。
- 新增 STA Tcl：`syn/scripts/sta_no_power.tcl`（只做 timing，不做 power，避免组合模块在 iEDA power 阶段崩溃）。

### 6.2 路径与调用约定

- `YOSYS_STA_DIR` 默认：`../ysyx/yosys-sta`
- `PDK_SRC_DIR` 默认：`../ysyx/mac/pdk/icsprout55-pdk`
- `Makefile` 会自动把 `$(PDK_SRC_DIR)` 链接到 `$(YOSYS_STA_DIR)/pdk/icsprout55`。

常用命令：

- 列出可跑模块：
  - `make sta-list`
- 跑单模块（示例）：
  - `make sta-module STA_MODULE=fa_core_controller STA_DATE=20260303`
  - `make sta-module STA_MODULE=fa_mul_sat_q8_8 STA_DATE=20260303`

说明：

- top 级当前不做 STA（按计划规避长时间运行）；
- 若修改时钟，可传 `STA_CLK_FREQ_MHZ=<freq>` 与 `STA_CLK_PORT=<port>`。

### 6.3 本次单模块估计结果（非 top）

1) `fa_core_controller`（时序模块）

- 结果目录：`syn/fa_core_controller_20260303/fa_core_controller-500MHz/`
- 关键文件：
  - `fa_core_controller.rpt`
  - `synth_stat.txt`
  - `sta.log`
- 摘要（来自 `fa_core_controller.rpt`）：
  - setup 最小 slack（WNS）约 `+1.437ns`（500MHz 约束下）
  - hold 最小 slack 约 `+0.150ns`
  - `TNS(max)=0`，`TNS(min)=0`
- 面积估计（来自 `synth_stat.txt`）：
  - `Chip area` 约 `531.16`

2) `fa_mul_sat_q8_8`（组合模块）

- 结果目录：`syn/fa_mul_sat_q8_8_20260303/fa_mul_sat_q8_8-500MHz/`
- 关键文件：
  - `fa_mul_sat_q8_8.rpt`
  - `synth_stat.txt`
  - `sta.log`
- 摘要：
  - 已成功生成 report；
  - 由于组合模块当前使用最小约束，报告中时钟/端点表为空（无完整时序约束），可作为早期连通性与规模估计参考。

### 6.4 结论

- 已实现“各种单元模块可单独综合/STA处理”的流程基线。
- 目前建议先沿该流程扩展到其余非 top 模块，再在后续阶段补组合模块 I/O 约束模板与 top 级 STA。
