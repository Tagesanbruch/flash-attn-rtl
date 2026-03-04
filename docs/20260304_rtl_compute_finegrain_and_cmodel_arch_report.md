# 20260304 RTL 细粒度计算耗时分析 + CModel 架构对比报告

## 1. 本轮目标与完成项

本轮完成了三件事：
1. 在 RTL 仿真中输出更细粒度的 compute 子阶段耗时，并生成条形图；
2. 在 cmodel 中扩展“固定指令流并行架构 vs 简单 NoC”周期模型并量化；
3. 基于（2）的结果，在 RTL 落地进一步并行化（dot lane / normalize 向量化），并复测。

---

## 2. 关键改动

### 2.1 RTL profiling 能力增强
- 文件：`dv/verilator_cpp/fa_attention_core_tb.cpp`
- 新增统计：
  - 主状态级：`ms_compute_cycles`, `ms_normalize_cycles`, `ms_other_cycles`
  - compute 子阶段：`cs_dp_cycles`, `cs_score_cycles`, `cs_softmax_pv_cycles`, `cs_ctrl_cycles`
- summary 新增字段并保证 `profiled_total_cycles == total_cycles`。

### 2.2 RTL 进一步并行化（固定指令流）
- 文件：`rtl/core/fa_attention_core.sv`
- 参数从上轮提升为：
  - `DP_LANES = 32`
  - `NORM_LANES = 8`

### 2.3 cmodel 架构模型扩展
- 文件：`cmodel/csrc/attention_experiment.cpp`, `cmodel/csrc/attention_core.hpp`, `cmodel/csrc/attention_lib.cpp`
- 在 compute-only 模型中新增：
  - `fixed_flow_l32_norm8_row2`
  - `fixed_flow_l32_norm8_row4`
  - `simple_noc_l16_norm4_row4`
  - `simple_noc_l32_norm8_row4`
- 新增 `noc_cycles` 字段并写入 CSV。

### 2.4 自动化流程与出图
- 文件：`Makefile`
- 新增目标：
  - `rtl-latency-profile`
  - `cmodel-compute-adv`
  - `rtl-cmodel-compare`
- 工具脚本：
  - 增强 `utils/analyze_latency_breakdown.py`（支持细分 compute 与 RTL-vs-cmodel 对比导出）
  - 新增 `utils/plot_rtl_cmodel_compare.py`

---

## 3. 结果（实测）

### 3.1 RTL 总体结果
- 来自 `docs/data/20260304_rtl_summary.csv`
- `total_cycles = 433,408`
- 精度：`rtl_fp32_mae = 0.000971925`, `rtl_fp32_maxae = 0.00203197`（门限 PASS）

相对上轮（`566,528`）本轮 RTL 周期下降约 **23.5%**。

### 3.2 RTL 细粒度 compute 分解
- `ms_compute_cycles = 394,368`
- `ms_normalize_cycles = 2,048`
- `cs_dp_cycles = 196,608`
- `cs_score_cycles = 65,536`
- `cs_softmax_pv_cycles = 65,536`
- `cs_ctrl_cycles = 66,688`

结论：当前 compute 内部仍是 **DP 与控制开销主导**，尤其 `DP + Ctrl` 是后续继续压缩的核心。

### 3.3 cmodel 架构对比（compute-only）
- 来自 `docs/data/20260304_compute_cycle_models_s256d64.csv`
- 关键模型：
  - `fixed_flow_l32_norm8_row2`: `100,608` cycles
  - `fixed_flow_l32_norm8_row4`: `51,328` cycles
  - `simple_noc_l32_norm8_row4`: `71,808` cycles（含 `noc_cycles=20,480`）

结论：在当前问题规模下，**简单 NoC 并非必要条件**；固定指令流并行已经能达到低周期，NoC 反而引入显著调度/同步开销。

---

## 4. RTL 与 CModel 的差异分析

对比文件：`docs/data/20260304_rtl_cmodel_compute_compare.csv`

以 `fixed_flow_l32_norm8_row2` 为基线：
- RTL `Compute+Norm_Total = 396,416`
- CModel `Compute+Norm_Total = 100,608`
- 差值约 `295,808`

差异来源：
1. cmodel 的行级并行/重叠是假设级吞吐模型；
2. RTL 当前尚未实现 row2 并行执行（只有 lane 与 norm 向量化）；
3. RTL 中仍存在显式状态切换与控制气泡（`cs_ctrl_cycles`）；
4. cmodel 未建模 RTL 级握手与控制边界条件。

---

## 5. 图表产物

- RTL 总体耗时条形图：`docs/report/20260304_rtl_latency_breakdown.png`
- RTL compute 细分条形图：`docs/report/20260304_rtl_compute_breakdown.png`
- RTL vs CModel 对比图：`docs/report/20260304_rtl_cmodel_compute_compare.png`

---

## 6. 关于“是否需要简单 NoC”

基于本轮 cmodel 结果，建议：
- **短期：不引入 NoC**，优先做固定指令流并行（风险更低、收益明确）。
- **中期：只有在行并行规模继续扩大且本地调度冲突明显时，再评估轻量 NoC。**

---

## 7. 下一步建议（按收益/风险排序）

1. 在 RTL 实现 `row2` 并行（优先），目标把 `cs_ctrl_cycles` 与 `ms_compute_cycles` 同步压低；
2. 在 compute 路径减少状态跳转（如合并部分控制边界）；
3. 保持当前 `DP_LANES=32`、`NORM_LANES=8`，先做结构并行再考虑更激进调度网络。

可直接执行：
```bash
make rtl-cmodel-compare
```

该命令会重跑 RTL、cmodel，并刷新 CSV 与三张图。
