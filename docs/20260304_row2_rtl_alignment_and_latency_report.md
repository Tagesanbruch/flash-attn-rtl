# 20260304 Row2 RTL对齐与延迟来源报告

## 1. 本轮结论（先看结果）

- 已完成 `row2` RTL并行实现（compute阶段每拍处理两条query row）。
- 最新 Verilator C++ TB结果：**`total_cycles = 236,288`**，已满足赛题 `<300,000` cycles 目标。
- 精度仍满足要求：`rtl_fp32_mae = 0.000971925`，`rtl_fp32_maxae = 0.00203197`。
- 与 `cmodel fixed_flow_l32_norm8_row2` 对齐后，compute-only仍有差距：
  - RTL `Compute+Norm = 199,296`
  - CModel `Compute+Norm = 100,608`
  - 差值 `+98,688` cycles（主要来自RTL控制/调度开销与阶段串行化）。

---

## 2. 当前RTL数据流（row2版本）

当前 `fa_attention_core` 的主流程：

1. `S_LOAD_Q`: 读入一个Q tile（`TQ=32` rows）。
2. `S_INIT_CONTEXT`: 初始化每个row的 `(m, l, acc)` 在线softmax上下文。
3. 对每个K/V tile循环：
   - `S_LOAD_K` -> `S_LOAD_V`
   - `S_COMPUTE`（内部FSM）
4. `S_NORMALIZE`: 对每个输出元素做 `acc/l` 归一化。
5. `S_WRITE_O`: 写回当前Q tile输出。
6. `S_NEXT_Q`: 进入下一Q tile。

### 2.1 Compute子FSM（row2并行）

`C_DP_INIT -> C_DP_RUN -> C_SCORE_DONE -> C_SOFTMAX_PREP -> C_NEXT_KJ -> C_NEXT_QI`

- `C_DP_RUN`：
  - `DP_LANES=32`，`D=64`，每个(q,k)点积需要 `DP_CHUNKS=2` 周期。
  - row2实现后，**同一组(kj, d-chunk)同时累计两条query row**：`dp_acc0/dp_acc1`。
- `C_SCORE_DONE`：两条row同时进行 scale 与 causal mask。
- `C_SOFTMAX_PREP`：两条row同时执行在线softmax更新：
  - `m <- max(m, score)`
  - `l <- l*exp(m_old-m_new) + exp(score-m_new)`
  - `acc <- acc*exp(m_old-m_new) + exp(score-m_new)*V`

本质上，row维度并行从 `1 -> 2`，直接把主要compute迭代的row扫描次数减半。

---

## 3. CModel延迟怎么计算（口径说明）

来源：`cmodel/csrc/attention_experiment.cpp` 中 `simulate_compute_cycles()`。

对某个架构模型（如 `fixed_flow_l32_norm8_row2`），compute-only延迟由下式给出：

1. 点积相关：

- `dp_cycles = dp_init_cycles + ceil(D / dot_lanes)`
- `steady = overlap_dp_post ? max(dp_cycles, post_cycles) : (dp_cycles + post_cycles)`
- `startup = overlap_dp_post ? (dp_cycles + post_cycles - 1) : (dp_cycles + post_cycles)`

2. row并行分组：

- `row_groups = ceil(S / rows_parallel)`
- `per_row_cycles = startup + (S - 1) * steady`
- `compute_cycles = row_groups * per_row_cycles`

3. 归一化与NoC开销：

- `norm_cycles = ceil(S * D / norm_vec)`
- `noc_cycles = row_groups * (S * noc_dispatch_per_k + noc_row_sync)`

4. 总compute-only：

- `total_compute_only_cycles = compute_cycles + norm_cycles + noc_cycles`

对于 `fixed_flow_l32_norm8_row2`：

- `dot_lanes=32, rows_parallel=2, norm_vec=8, overlap_dp_post=true`
- 结果：`compute=98,560`, `norm=2,048`, `total=100,608`。

> 注：该模型是“架构级周期估算”（不含DMA握手细节、主FSM细粒度控制气泡、实现相关串行边界）。

---

## 4. RTL延迟怎么来的（口径说明）

来源：`dv/verilator_cpp/fa_attention_core_tb.cpp` 实测周期统计，写入：

- `docs/data/20260304_rtl_summary.csv`
- `docs/data/20260304_rtl_latency_breakdown.csv`
- `docs/data/20260304_rtl_compute_breakdown.csv`

### 4.1 总周期与DMA拆解

- `total_cycles = 236,288`
- `DMA_RD_Q = 2,048`
- `DMA_RD_K = 16,384`
- `DMA_RD_V = 16,383`
- `DMA_WR_O = 2,048`
- `Compute+Normalize+Ctrl = 199,425`

### 4.2 Compute细分（ms/cs状态采样）

- `ms_compute_cycles = 197,248`
  - `cs_dp_cycles = 98,304`
  - `cs_score_cycles = 32,768`
  - `cs_softmax_pv_cycles = 32,768`
  - `cs_ctrl_cycles = 33,408`
- `ms_normalize_cycles = 2,048`

可见 row2 后 DP显著下降，但控制态与阶段切换仍占较大比例，形成与CModel理想值的主要差距。

---

## 5. RTL vs CModel（当前对齐状态）

来源：`docs/data/20260304_rtl_cmodel_compute_compare.csv`（cmodel模型：`fixed_flow_l32_norm8_row2`）

- `ComputeOnly`: RTL `197,248` vs CModel `98,560`（+`98,688`）
- `Normalize`: RTL `2,048` vs CModel `2,048`（完全对齐）
- `Compute+Norm_Total`: RTL `199,296` vs CModel `100,608`（+`98,688`）

说明：

1. **归一化向量化口径已对齐**（`NORM_LANES=8` -> `norm=2,048`一致）。
2. 主要差距集中在compute主循环中的**控制/串行化开销**，而不是算法公式或norm资源设定。

---

## 6. 是否需要继续“先在cmodel优化一轮”？

根据本轮结果，赛题硬目标（`<300k`）已达成，因此本轮按要求先完成阶段性收敛，不再强制进入“未达标时的cmodel先优化分支”。

如果进入下一轮（追求更大余量/更高吞吐），建议优先在CModel验证以下两类再映射RTL：

1. **降低控制开销口径**：把 `post/control` 从3拍进一步压缩，评估理论下限；
2. **跨阶段重叠**：在模型里显式引入 `Load(K/V)` 与前一组 `compute` 的部分重叠，评估端到端而非compute-only最优点。

---

## 7. 本轮产物清单

- RTL实现：`rtl/core/fa_attention_core.sv`（row2并行）
- 周期结果：`docs/data/20260304_rtl_summary.csv`
- 延迟拆解：`docs/data/20260304_rtl_latency_breakdown.csv`
- compute细拆：`docs/data/20260304_rtl_compute_breakdown.csv`
- RTL/CModel对比：`docs/data/20260304_rtl_cmodel_compute_compare.csv`
- 图表：
  - `docs/report/20260304_rtl_latency_breakdown.png`
  - `docs/report/20260304_rtl_compute_breakdown.png`
  - `docs/report/20260304_rtl_cmodel_compute_compare.png`
