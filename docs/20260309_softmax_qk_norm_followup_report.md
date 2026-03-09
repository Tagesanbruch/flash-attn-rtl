# 2026-03-09 Follow-up：Online Softmax / QK / Norm 第二轮实验与架构取舍

## 1. 背景

本轮是在第一版实验总结 [docs/20260309_design_report_driven_experiments.md](docs/20260309_design_report_driven_experiments.md) 基础上继续推进，目标是：

1. 把 Online Softmax 独立模块尽量推过 `500MHz`；
2. 为 QK dot-product 与 Norm 再补 `2~3` 个实验；
3. 结合 `MAC16` 与 `SpAtten` 参考，判断 QK 是否应该从当前宽并行树转向串行 / 阵列式组织；
4. 估算这些方案对当前 `fa_attention_core` 调度周期的影响。

参考资料：
- [ref/MAC16/docs/2026-02-03-exp_sk-score-update.md](ref/MAC16/docs/2026-02-03-exp_sk-score-update.md)
- [ref/MAC16/docs/2026-01-26-exp-h-i-j-k-results.md](ref/MAC16/docs/2026-01-26-exp-h-i-j-k-results.md)
- [ref/spatten/spatten_hardware/hardware/src/main/scala/spatten/DotProduct.scala](ref/spatten/spatten_hardware/hardware/src/main/scala/spatten/DotProduct.scala)
- [docs/2026-03-06-serialization-architecture-analysis.md](docs/2026-03-06-serialization-architecture-analysis.md)
- [docs/20260309_attention_core_theoretical_analysis.md](docs/20260309_attention_core_theoretical_analysis.md)

---

## 2. 本轮新增实验

### 2.1 Online Softmax

新增：
- [experiments/fa_online_softmax_ctx/exp_c/fa_online_softmax_ctx.sv](experiments/fa_online_softmax_ctx/exp_c/fa_online_softmax_ctx.sv)
- [experiments/fa_online_softmax_ctx/exp_d/fa_online_softmax_ctx.sv](experiments/fa_online_softmax_ctx/exp_d/fa_online_softmax_ctx.sv)

要点：
- `exp_c`：在 `exp_b` 的 4-context 基础上，加入写回前递（forwarded state bypass），避免同 context 紧邻输入时读到旧 `m/l/acc`；
- `exp_d`：在 `exp_c` 基础上再拆一拍，把最终 `l/acc` 求和与状态写回分成 `s4`，进一步缩短 recurrence datapath。

### 2.2 Norm

新增：
- [experiments/fa_o_normalize_block_pipe/exp_c/fa_o_normalize_block_pipe.sv](experiments/fa_o_normalize_block_pipe/exp_c/fa_o_normalize_block_pipe.sv)
- [experiments/fa_o_normalize_block_pipe/exp_d/fa_o_normalize_block_pipe.sv](experiments/fa_o_normalize_block_pipe/exp_d/fa_o_normalize_block_pipe.sv)

要点：
- `exp_c`：把乘法结果先寄存，再做 rounding / saturation；
- `exp_d`：把 `recip_q16_16` 拆成高低半字，改为部分积 `pp_lo/pp_hi` 相加，降低单个乘法器的组合压力。

### 2.3 QK dot-product

新增：
- [experiments/fa_qk_dotprod_slice_pipe/exp_c/fa_qk_dotprod_slice_pipe.sv](experiments/fa_qk_dotprod_slice_pipe/exp_c/fa_qk_dotprod_slice_pipe.sv)
- [experiments/fa_qk_dotprod_slice_pipe/exp_d/fa_qk_dotprod_slice_pipe.sv](experiments/fa_qk_dotprod_slice_pipe/exp_d/fa_qk_dotprod_slice_pipe.sv)
- [experiments/fa_qk_dotprod_slice_pipe/exp_e/fa_qk_dotprod_slice_pipe.sv](experiments/fa_qk_dotprod_slice_pipe/exp_e/fa_qk_dotprod_slice_pipe.sv)

要点：
- `exp_c`：2 组分块 + 1 级归并；
- `exp_d`：4 组分块 + 2 级归并；
- `exp_e`：8 组分块 + `qtr/half/final` 三级归并，进一步压低局部 adder-tree 深度。

---

## 3. 功能验证状态

本轮新增实验已完成功能验证：

- `fa_online_softmax_ctx`: `exp_c / exp_d` PASS
- `fa_o_normalize_block_pipe`: `exp_c / exp_d` PASS
- `fa_qk_dotprod_slice_pipe`: `exp_c / exp_d / exp_e` PASS

结合上一轮结果，当前三组实验家族共 `16` 个变体均已通过功能验证。

---

## 4. 最新综合 / STA 结果（500MHz）

> 说明：以下结果来自 `20260309` 当天实验目录；`exp_c` 的 QK STA 日志未完整落盘，因此记为 unavailable。

| Module | Exp | Area | Worst Slack(ns) | Est Fmax(MHz) | TNS | Endpoint |
|---|---:|---:|---:|---:|---:|---|
| fa_online_softmax_ctx | base | 22812.72 | -2.667 | 214.2 | -873.259 | `acc_state[0]_23__reg_p:D` |
| fa_online_softmax_ctx | exp_a | 24360.28 | -2.117 | 242.9 | -676.769 | `l_state[0]_24__reg_p:D` |
| fa_online_softmax_ctx | exp_b | 25509.96 | -0.298 | 435.1 | -64.357 | `acc_state[2]_31__reg_p:D` |
| fa_online_softmax_ctx | exp_c | 26433.68 | 0.105 | 527.6 | 0.000 | `s3_v_mul_q9_23_31__reg_p:D` |
| fa_online_softmax_ctx | exp_d | 27216.28 | 0.135 | 536.2 | 0.000 | `s3_acc_scaled_q33_31_31__reg_p:D` |
| fa_o_normalize_block_pipe | base | 228202.52 | -1.786 | 264.1 | -444.065 | `o_data_flat[79]_reg_p:D` |
| fa_o_normalize_block_pipe | exp_a | 228339.72 | -1.819 | 261.8 | -454.762 | `lo_r_63__reg_p:D` |
| fa_o_normalize_block_pipe | exp_b | 228817.68 | -1.776 | 264.8 | -435.131 | `mid_r_23__reg_p:D` |
| fa_o_normalize_block_pipe | exp_c | 233672.04 | -0.995 | 333.9 | -769.428 | `s0_mul[7]_94__reg_p:D` |
| fa_o_normalize_block_pipe | exp_d | 238672.84 | -0.772 | 360.8 | -681.443 | `s0_pp_lo[4]_79__reg_p:D` |
| fa_qk_dotprod_slice_pipe | base | 290293.08 | NA | NA | NA | STA failed / unavailable |
| fa_qk_dotprod_slice_pipe | exp_a | 285153.12 | -9.881 | 84.2 | -1597.806 | `sum1_hi_r_39__reg_p:D` |
| fa_qk_dotprod_slice_pipe | exp_b | 280647.08 | -5.479 | 133.7 | -2050.679 | `q1_sum_r[2]_39__reg_p:D` |
| fa_qk_dotprod_slice_pipe | exp_c | 284261.04 | NA | NA | NA | STA log incomplete / unavailable |
| fa_qk_dotprod_slice_pipe | exp_d | 280897.96 | -5.546 | 132.5 | -2075.535 | `mac1_r[1]_39__reg_p:D` |
| fa_qk_dotprod_slice_pipe | exp_e | 273621.04 | -2.906 | 203.8 | -2313.320 | `mac1_r[6]_39__reg_p:D` |

---

## 5. 结论一：Online Softmax 已经独立闭合 500MHz

### 5.1 直接结论

`fa_online_softmax_ctx/exp_c` 与 `exp_d` 都已经在 500MHz 约束下得到正 slack：

- `exp_c`: `WNS = +0.105ns`, `Fmax ≈ 527.6MHz`
- `exp_d`: `WNS = +0.135ns`, `Fmax ≈ 536.2MHz`

这说明：

- 第一轮里 `exp_b` 的方向是正确的；
- 决定胜负的不只是“更深流水”，而是 **deeper pipeline + recurrence bypass**；
- 当前最有价值的主线改造对象，已经非常明确地落在 Online Softmax 上。

### 5.2 为什么这轮能过 500MHz

关键不是单纯再打一拍，而是把 recurrence 上的“旧状态读取”改成：

1. 先查 `m_state/l_state/acc_state`；
2. 若同 context 的结果正处在 `s3/s4`，优先取流水线内的更新值；
3. 再把最终加法写回单独放一拍。

这样做以后，关键路径从“状态 RAM / flop → 比较/exp/mul/add → 写回”收缩为更局部的寄存器到寄存器链。

### 5.3 对主线的含义

建议把 [experiments/fa_online_softmax_ctx/exp_d/fa_online_softmax_ctx.sv](experiments/fa_online_softmax_ctx/exp_d/fa_online_softmax_ctx.sv) 作为主线 `fa_online_softmax_pair` 的直接参考版本。

优先保留的特征：
- `4-context interleave`
- `state forwarding`
- `4~5 stage` 拆分
- `exp` / `scale` / `acc update` 解耦

---

## 6. 结论二：Norm 有改善，但仍不值得优先投入

### 6.1 结果解读

相较第一轮：

- `exp_c`: `264MHz -> 334MHz`
- `exp_d`: `264MHz -> 360.8MHz`

说明 Norm 并非完全“不可救”，而是：

- 仅靠轻量寄存器插入，收益小；
- 但把 `32x64` 乘法拆成高低部分积后，确实能明显缩短关键路径。

### 6.2 为什么仍然不建议排到第一优先级

即便最好版本 `exp_d`，离 500MHz 仍有较大差距；同时该路径位于输出归一化末端，不是当前总周期主导项。

更现实的主线策略是：

1. 先把 Online Softmax 做到主线可用；
2. 再把 QK 的并行形态定下来；
3. 最后再决定 Norm 是继续拆部分积，还是放到系统级 overlap 中统一掩蔽。

---

## 7. 结论三：QK 深化流水后仍远离 500MHz

### 7.1 实验趋势

QK 新一轮实验的趋势非常一致：

- adder-tree 分得越细，频率越高；
- 面积略有下降；
- 但最佳也只有 `203.8MHz`，距离 `500MHz` 仍差很远。

`exp_e` 已经把 32-lane 点积拆成：

- `8` 个局部乘加块
- `4` 个 quarter sums
- `2` 个 half sums
- `1` 个 final sum

这比单纯 2/4-way 归并好很多，但仍然没有越过“宽输入 + 大量 16x16 乘法 + 大量 40-bit 加法寄存”的根本负担。

### 7.2 现阶段判断

QK 的问题已经不是“要不要再多打一拍”，而是：

- 当前 `32 lane × 2 row` 的宽并行 dot-product 组织，**空间并行度过高**；
- 如果继续保持这条宽总线，想用普通寄存器切分直接到 500MHz，代价会越来越大，收益会越来越小。

---

## 8. MAC16 / SpAtten 参考后的架构判断

### 8.1 从 MAC16 学到什么

从 [ref/MAC16/docs/2026-01-26-exp-h-i-j-k-results.md](ref/MAC16/docs/2026-01-26-exp-h-i-j-k-results.md) 可以看到：

- 深流水 `exp_k` 能把 isolated MAC 推到 `1GHz+`；
- 但串行乘法实验 `exp_j` 虽然面积很小，时序和功耗都不理想；
- MAC16 的高频成立前提是：**局部算子 isolated + 深流水 + 业务可接受额外 latency**。

从 [ref/MAC16/docs/2026-02-03-exp_sk-score-update.md](ref/MAC16/docs/2026-02-03-exp_sk-score-update.md) 也能看到：

- 串行 / 深流水 MAC 的 STA 可以非常漂亮；
- 但 PR、功耗、FM、拥塞并不会自动变简单；
- 它更适合作为“如何切断乘法压缩树”的参考，而不是直接照搬为 FA 的业务形态。

### 8.2 从 SpAtten 学到什么

[ref/spatten/spatten_hardware/hardware/src/main/scala/spatten/DotProduct.scala](ref/spatten/spatten_hardware/hardware/src/main/scala/spatten/DotProduct.scala) 的核心特征不是 bit-serial，而是：

- `query` / `key` 通过 broadcast-reuse 方式分发；
- 内部仍保留一组 `numMultipliers` 并行乘法器；
- 用更规整的阵列式/广播式结构完成 dot-product，而不是“大一坨平面 reduction tree”。

换言之，SpAtten 更接近：

- **中等宽度阵列 + 广播复用 + 可持续发射**

而不是：

- **位串行 MAC16 式慢速输入/输出**。

### 8.3 对 QK 的推荐结论

**不建议把 QK 改成 MAC16 式 bit-serial / word-serial 输入输出结构。**

原因：

1. 当前 `fa_attention_core` 调度是以 `DP_CHUNKS=2` 为基础设计的；
2. 真正串行化会把 `C_DP_RUN` 成倍拉长；
3. 会破坏当前 `145k~149k cycles` 的 baseline 优势；
4. 上层还要引入串并转换、对齐 FIFO、额外 stall 控制，系统复杂度大幅上升。

**更可取的方向是：保留 16-bit word-parallel，缩小空间并行度，转为规则 MAC-array / tiled reduction。**

推荐候选：
- `16-lane` pipelined MAC-array
- `8-lane` pipelined MAC-array
- `2-row interleave + II=1` 的广播式 dot-product

这更接近 SpAtten 的组织方式，也更符合本项目当前控制流。

---

## 9. 对当前 `fa_attention_core` 周期的影响估算

当前理论分析里，QK/score/softmax-prep 的微步骤总数为：

- score-pair 数：`32768`
- 当前每个 pair：`DP_RUN=2` + `SCORE_DONE=1` + `SOFTMAX_PREP=1`
- 即当前 compute 主体为：`4 cycles/pair = 131072 cycles`

参考 [docs/20260309_attention_core_theoretical_analysis.md](docs/20260309_attention_core_theoretical_analysis.md) 与 [docs/report_0306/01_项目摘要与阶段结论.md](docs/report_0306/01_项目摘要与阶段结论.md)，当前整核总周期量级约在 `148656` 左右。

若只改变 QK 的 `DP_LANES`，保持其余流程不变，则：

| QK organization | DP chunks / pair | cycles / pair | compute total | vs current compute | est total core cycles |
|---|---:|---:|---:|---:|---:|
| current `32-lane` | 2 | 4 | 131072 | baseline | 148656 |
| `16-lane` array | 4 | 6 | 196608 | +65536 | 214192 |
| `8-lane` array | 8 | 10 | 327680 | +196608 | 345264 |
| `4-lane` array | 16 | 18 | 589824 | +458752 | 607408 |
| `1-lane` serial | 64 | 66 | 2162688 | +2031616 | 2180272 |

结论：

- `16-lane` 阵列化仍在 `300k` 周期约束内，有继续探索价值；
- `8-lane` 在不做更强 overlap 的情况下，已经明显高于当前基线并超过 `300k`；
- `4-lane` 或真正串行基本不可接受；
- 因此，QK 的合理搜索区间应优先放在 **`16-lane` 或带更强 overlap 的 `8-lane` 阵列**，而不是 bit-serial。

### 9.1 Online Softmax / Norm 的周期影响

- Online Softmax `exp_c/exp_d` 增加的是 pipeline latency，不是吞吐必然下降；
- 若主线按 `context/qpair` 做交错发射，目标应该是维持 `II≈1`，则总周期只增加 fill/drain 开销；
- Norm `exp_c/exp_d` 同样更像 latency 增长，而不是吞吐下降，系统级周期影响远小于 QK 宽度变化。

因此：

- **真正会大幅改变总 cycles 的只有 QK 空间并行度缩减**；
- Online Softmax 与 Norm 的流水深化，更像是为 500MHz 服务的“时序重构”，不是“周期灾难项”。

---

## 10. 最终建议

### 建议 A：主线优先接入 Online Softmax `exp_d`

优先级最高，原因：
- 已独立过 500MHz；
- 面积增量可控；
- 对总周期影响最小。

### 建议 B：QK 不做 bit-serial，转做 `16-lane` 或 `8-lane` MAC-array 原型

推荐下一轮实验方向：
- `16-lane` array + 2~3 stage local reduction
- `8-lane` array + query/key broadcast reuse
- 两个 row-pair 交错发射，验证能否维持 `II=1`

### 建议 C：Norm 暂列第三优先级

若需要继续打磨，优先保留 `exp_d` 的部分积拆分思路；但在主线资源分配上不应先于 Online Softmax 与 QK 阵列化。

---

## 11. 一句话结论

- **Online Softmax：已经达到可主线化的 500MHz 级别。**
- **Norm：可改进，但不是决定性突破口。**
- **QK：不能继续押注“超宽并行树 + 多打一拍”，也不该走 MAC16 式串行；最合理方向是中等宽度、深流水、广播复用的 MAC-array。**
