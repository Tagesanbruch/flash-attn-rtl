# flashattn（RTL + CModel + DV + STA）

本仓库用于赛题二（FlashAttention-style SDPA IP）开发，当前主线是：
- Baseline：`S=256, D=64, Q/K/V/O=Q8.8`，在线 softmax、tile 流式、不存 `SxS`；
- 验证：cocotb + Verilator C++ TB + CModel 对照；
- 评估：周期/误差/带宽统计 + 模块级 STA。

## 当前状态（2026-03-11）

当前仓库只有一条活动主线 `main`。这条主线已经完成：

- `QK tag` 化流式回收
- `4-context` online softmax 调度
- `acc -> normalize` 尺度对齐修正

基于顶层 full-run cocotb 回归（`make test MODULE=fa_attention_ip_top`），当前主线结果为：

- `total_cycles = 85,928`
- `rtl_vs_fixed_q8_8_mae_lsb = 0`
- `rtl_vs_fixed_q8_8_max_err_lsb = 0`
- `rtl_fp32_mae = 0.002499`
- `rtl_fp32_maxae = 0.006583`

对应 perf 摘要为：

- `compute = 67,584 cycles`
- `dp = 66,560`
- `score = 32,768`
- `softmax = 32,768`
- `norm = 5,888`
- `rd_beat = 34,816`
- `wr_beat = 2,048`

说明：仓库中出现过的 `145,584 cycles` 与 `608,296 cycles` 仍有历史价值，但都不再代表当前 `main`：

- `145,584`：较早一版稳定 baseline 的历史结果；
- `608,296`：高频 leaf 接回但 system overlap 尚未打通时的中间恢复态；
- `85,928`：当前唯一活动主线 `main` 的最新实测结果。

建议配合阅读：

- [docs/20260310_current_cycle_perf_and_accuracy_analysis.md](docs/20260310_current_cycle_perf_and_accuracy_analysis.md)
- [docs/20260311_mainline_status_and_next_step_strategy.md](docs/20260311_mainline_status_and_next_step_strategy.md)

## 环境准备

推荐：
```bash
make setup-py
```

该命令会创建 `.venv` 并安装：`cocotb`, `pytest`, `numpy`。

> 依赖工具：`verilator`, `python3`, `g++`。

---

## 一键常用命令（根 Makefile）

### 1) 基础验证（cocotb）

```bash
make list
make test MODULE=fa_attention_core
make test MODULE=fa_attention_core_full
make regress
```

- `fa_attention_core`：小参数快速回归（编译参数覆盖到 `SEQ_LEN=32,D=8,TQ=8,TK=8`）
- `fa_attention_core_full`：默认参数全量（`256/64/32/64`）
- 输出：`dv/cocotb/sim_build/<MODULE>/results.xml`

### 2) RTL lint

```bash
make lint
```

覆盖主要模块（mul/exp/recip/softmax/controller/dma/core/top）的 Verilator lint。

### 3) C++ 对照与直跑

```bash
make check-sdpa-cpp
make check-sdpa-verilator-cpp
```

- `check-sdpa-cpp`：先跑 cocotb full + dump，再跑 `dv/verilator_cpp/sdpa_compare.cpp` 比较
- `check-sdpa-verilator-cpp`：直接运行 C++ Verilator TB

### 4) 周期剖析与 RTL-vs-CModel 对比

```bash
make rtl-latency-profile
make cmodel-compute-adv
make rtl-cmodel-compare
```

产物（含历史与当前阶段）：
- `docs/data/20260304_rtl_summary.csv`
- `docs/data/20260304_rtl_timeline.csv`
- `docs/data/20260304_rtl_latency_breakdown.csv`
- `docs/data/20260304_rtl_compute_breakdown.csv`
- `docs/data/20260304_compute_cycle_models_s256d64.csv`
- `docs/data/20260304_rtl_cmodel_compute_compare.csv`
- `docs/data/20260311_rtl_summary_ctxstream.csv`
- 图表：`docs/report/20260304_*.png`

### 5) STA（模块级）

```bash
make sta-list
make sta MODULE=fa_core_controller
# 或指定：
make sta STA_MODULE=fa_core_controller STA_CLK_FREQ_MHZ=500 STA_CLK_PORT=clk
```

说明：
- 需要 `YOSYS_STA_DIR` 与 `PDK_SRC_DIR` 路径可用（默认见根 `Makefile`）
- 输出目录：`syn/<module>_<date>/`

---

## CModel 使用

`cmodel/Makefile` 已封装常用实验：

```bash
make -C cmodel build
make -C cmodel run
make -C cmodel sweep
make -C cmodel run-mask-sweep
make -C cmodel run-stage-decomp
make -C cmodel run-compute-cycles
make -C cmodel run-solution-compare
```

关键输出：
- `docs/data/20260304_cmodel_modes_*.csv`
- `docs/data/20260304_cmodel_mask_sweep_*.csv`
- `docs/data/20260304_stage_decomp_*.csv`
- `docs/data/20260304_compute_cycle_models_s256d64.csv`
- `docs/data/20260304_solution_compare_*.csv`

---

## 项目结构（开发关注）

```text
rtl/
  bus/       AXI-Lite 与 DMA 接口相关模块
  core/      attention 核心（主状态机/compute/normalize）
  softmax/   exp/recip/online-softmax 相关模块
  top/       IP 顶层

dv/
  cocotb/         Python + cocotb 回归
  verilator_cpp/  C++ testbench 与独立比较器
  python/         算法审计/torch 对比脚本

cmodel/
  csrc/       功能模型、误差分解、周期模型
  Makefile    各类 sweep/compare 入口

syn/
  <module>_YYYYMMDD/  历史综合/STA 结果
  scripts/            STA 脚本
  sdc/                约束模板

docs/
  data/   CSV 指标产物
  report/ 图表与阶段报告
```

---

## 建议开发节奏（后续）

1. 先冻结当前 `main` 作为可提交 baseline；
2. 新实验优先单独开分支，不要直接破坏 `85,928 cycles` 主线；
3. 每次改动至少跑：
   - `make lint`
  - `make test MODULE=fa_attention_ip_top`
   - `make check-sdpa-verilator-cpp`
   - `make rtl-latency-profile`
4. 再用 `make rtl-cmodel-compare` 看周期差异来源。

若目标是 Baseline P0，请优先看：
- `docs/20260305_architecture_next_steps_from_papers.md`

若目标是下一步分支规划，请优先看：
- [docs/20260311_mainline_status_and_next_step_strategy.md](docs/20260311_mainline_status_and_next_step_strategy.md)
