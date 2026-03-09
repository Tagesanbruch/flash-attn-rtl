# 设计报告驱动实验：datapath 微架构实验与指标总结

## 1. 实验目标

根据 [report/20260309-miromind.md](report/20260309-miromind.md) 中给出的下一阶段建议，本次在 `experiments/` 下新增了 3 组针对已拆分 datapath 的独立实验，用于回答以下问题：

1. `QK` 点积路径做多级流水后，时序是否明显改善；
2. online softmax 引入 multi-context 与更细 base-2 LUT 后，吞吐/时序是否改善；
3. normalize 路径增加分段流水或输出 staging 后，是否能带来有意义的 STA 改善。

## 2. 新增实验目录

### 2.1 QK 点积流水实验

目录：
- [experiments/fa_qk_dotprod_slice_pipe/base/fa_qk_dotprod_slice_pipe.sv](experiments/fa_qk_dotprod_slice_pipe/base/fa_qk_dotprod_slice_pipe.sv)
- [experiments/fa_qk_dotprod_slice_pipe/exp_a/fa_qk_dotprod_slice_pipe.sv](experiments/fa_qk_dotprod_slice_pipe/exp_a/fa_qk_dotprod_slice_pipe.sv)
- [experiments/fa_qk_dotprod_slice_pipe/exp_b/fa_qk_dotprod_slice_pipe.sv](experiments/fa_qk_dotprod_slice_pipe/exp_b/fa_qk_dotprod_slice_pipe.sv)
- [experiments/fa_qk_dotprod_slice_pipe/tb/test_fa_qk_dotprod_slice_pipe.py](experiments/fa_qk_dotprod_slice_pipe/tb/test_fa_qk_dotprod_slice_pipe.py)

实验定义：
- `base`：单级寄存输出的组合归约
- `exp_a`：2 段归约流水
- `exp_b`：4 象限归约 + 3 级流水

### 2.2 Online softmax 多 context 实验

目录：
- [experiments/fa_online_softmax_ctx/base/fa_online_softmax_ctx.sv](experiments/fa_online_softmax_ctx/base/fa_online_softmax_ctx.sv)
- [experiments/fa_online_softmax_ctx/exp_a/fa_online_softmax_ctx.sv](experiments/fa_online_softmax_ctx/exp_a/fa_online_softmax_ctx.sv)
- [experiments/fa_online_softmax_ctx/exp_b/fa_online_softmax_ctx.sv](experiments/fa_online_softmax_ctx/exp_b/fa_online_softmax_ctx.sv)
- [experiments/fa_online_softmax_ctx/tb/test_fa_online_softmax_ctx.py](experiments/fa_online_softmax_ctx/tb/test_fa_online_softmax_ctx.py)

实验定义：
- `base`：2-context、单级更新、粗粒度 16-entry base-2 LUT
- `exp_a`：2-context、2 级流水、粗粒度 16-entry LUT
- `exp_b`：4-context、3 级流水、更细粒度 32-entry LUT

### 2.3 Normalize 流水实验

目录：
- [experiments/fa_o_normalize_block_pipe/base/fa_o_normalize_block_pipe.sv](experiments/fa_o_normalize_block_pipe/base/fa_o_normalize_block_pipe.sv)
- [experiments/fa_o_normalize_block_pipe/exp_a/fa_o_normalize_block_pipe.sv](experiments/fa_o_normalize_block_pipe/exp_a/fa_o_normalize_block_pipe.sv)
- [experiments/fa_o_normalize_block_pipe/exp_b/fa_o_normalize_block_pipe.sv](experiments/fa_o_normalize_block_pipe/exp_b/fa_o_normalize_block_pipe.sv)
- [experiments/fa_o_normalize_block_pipe/tb/test_fa_o_normalize_block_pipe.py](experiments/fa_o_normalize_block_pipe/tb/test_fa_o_normalize_block_pipe.py)

实验定义：
- `base`：整向量单拍计算 + 输出寄存
- `exp_a`：低/高半向量拆分后再输出
- `exp_b`：整向量计算后增加 staging/fifo 风格寄存

### 2.4 实验指标汇总脚本

- [experiments/collect_metrics.py](experiments/collect_metrics.py)

该脚本会从 `syn/exp_*` 中读取 `synth_stat.txt` 与 `sta.log`，输出面积、worst slack、估算频率和 TNS，并在 STA 缺失时保留 synth 面积。

## 3. 构建系统适配

已更新 [experiments/Makefile](experiments/Makefile#L24-L28)，使新模块被识别为 clocked module，能够直接执行：

- `make -C experiments verif MOD=<mod> EXP=<exp>`
- `make -C experiments sta MOD=<mod> EXP=<exp> STA_DATE=20260309`

## 4. 功能验证结果

本次新增实验共 9 个变体，全部通过功能验证：

- `fa_qk_dotprod_slice_pipe`: `base / exp_a / exp_b` 全部 PASS
- `fa_online_softmax_ctx`: `base / exp_a / exp_b` 全部 PASS
- `fa_o_normalize_block_pipe`: `base / exp_a / exp_b` 全部 PASS

说明：
- 点积实验验证了随机流输入下的精确 dot-product 输出；
- softmax 实验验证了多 context、不同 pipeline latency 下的状态更新与行结束脉冲；
- normalize 实验验证了 `den_zero`、随机 `recip` 和 8-lane 向量输出的一致性。

## 5. STA / 综合指标

约束：默认 500 MHz。

| Module | Exp | Area | Worst Slack(ns) | Est Fmax(MHz) | TNS | Endpoint |
|---|---:|---:|---:|---:|---:|---|
| fa_online_softmax_ctx | base | 22812.72 | -2.667 | 214.2 | -873.259 | acc_state[0]_23__reg_p:D |
| fa_online_softmax_ctx | exp_a | 24360.28 | -2.117 | 242.9 | -676.769 | l_state[0]_24__reg_p:D |
| fa_online_softmax_ctx | exp_b | 25509.96 | -0.298 | 435.1 | -64.357 | acc_state[2]_31__reg_p:D |
| fa_o_normalize_block_pipe | base | 228202.52 | -1.786 | 264.1 | -444.065 | o_data_flat[79]_reg_p:D |
| fa_o_normalize_block_pipe | exp_a | 228339.72 | -1.819 | 261.8 | -454.762 | lo_r_63__reg_p:D |
| fa_o_normalize_block_pipe | exp_b | 228817.68 | -1.776 | 264.8 | -435.131 | mid_r_23__reg_p:D |
| fa_qk_dotprod_slice_pipe | base | 290293.08 | NA | NA | NA | STA failed / unavailable |
| fa_qk_dotprod_slice_pipe | exp_a | 285153.12 | -9.881 | 84.2 | -1597.806 | sum1_hi_r_39__reg_p:D |
| fa_qk_dotprod_slice_pipe | exp_b | 280647.08 | -5.479 | 133.7 | -2050.679 | q1_sum_r[2]_39__reg_p:D |

## 6. 结果分析

### 6.1 Online softmax：`exp_b` 明显优于 `base/exp_a`

观察：
- `base -> exp_a`：面积从 `22.8k` 增至 `24.4k`，但估算频率从 `214 MHz` 提升到 `243 MHz`，有一定改善；
- `exp_a -> exp_b`：面积进一步到 `25.5k`，但估算频率显著升至 `435 MHz`，worst slack 逼近收敛。

结论：
- **4-context + 更细 LUT + 更深流水** 是当前三组实验里最有效的改进；
- 这与设计报告的判断一致：online softmax 是最值得优先做结构级优化的路径；
- 从独立模块视角看，`exp_b` 已经接近 500 MHz，可作为后续 RTL 主线重构的首选参考。

### 6.2 Normalize：仅做流水拆分收益有限

观察：
- `base / exp_a / exp_b` 三者面积都在 `228k` 左右，差异很小；
- 估算频率都停留在 `262~265 MHz`；
- `exp_a` 甚至略差，`exp_b` 也只有极小改善。

结论：
- 对 normalize 路径而言，**单纯增加寄存或半向量拆分，不足以显著改善主瓶颈**；
- 真正需要的是更高层级的结构改动，例如：
  - 提前发起 reciprocal；
  - normalize 与 writeback overlap；
  - 降低 64-bit 乘法与饱和逻辑的关键路径长度。

### 6.3 QK 点积：流水有帮助，但当前结构依然太重

观察：
- `base` 综合面积最大，为 `290.3k`；
- `exp_a` 降到 `285.2k`，估算频率仅 `84 MHz`；
- `exp_b` 进一步降到 `280.6k`，估算频率提升到 `134 MHz`；
- `base` 在本机 STA 过程中出现 `Error 137`，未完成时序收敛，说明图规模/内存压力很高。

结论：
- 对 QK 路径，简单的“归约树分段流水”**方向是对的**，因为 `exp_b` 明显优于 `exp_a` 和 `base`；
- 但当前 32-lane 乘加树仍然过重，距离 500 MHz 非常远；
- 这意味着后续若要在主线中继续推进，不能只靠“多加几级寄存”，更可能需要：
  - 更小粒度的 reduction tree；
  - lane 级或块级 systolic/reduction 结构；
  - 调整 `DP_LANES` 并用更高层 overlap 补回 cycles。

## 7. 对主线 RTL 的启发

### 优先级 1：先推进 online softmax 方向

原因：
- 是本次实验里唯一看到明显时序收敛收益的路径；
- 面积增量相对可控；
- 更符合 [report/20260309-miromind.md](report/20260309-miromind.md) 的 A/B 路线。

建议：
- 以 `fa_online_softmax_ctx/exp_b` 为参考，下一步把 `fa_online_softmax_pair` 往：
  - `4-context`
  - `3-stage pipeline`
  - `fine base-2 LUT`
  的方向推进。

### 优先级 2：QK 需要更激进的数据通路重构

建议：
- 不直接把当前 `fa_qk_dotprod_slice` 原样加更多寄存；
- 优先研究：
  - 更平衡的 adder tree；
  - smaller-chunk / sub-lane reduction；
  - 或小型 systolic 化。

### 优先级 3：Normalize 暂不作为独立突破点

建议：
- 先不在主线投入太多精力做纯 normalize pipeline 微调；
- 更适合把它放到“row-level overlap / reciprocal 前移 / writeback 重叠”联动优化里统一处理。

## 8. 结论

本次实验说明：

1. **online softmax 路径最值得优先优化**，并且 `4-context + deeper pipeline + fine LUT` 已展示出接近 500 MHz 的独立模块潜力；
2. **QK 路径仅靠浅层流水仍不足够**，需要更结构化的 reduction/systolic 思路；
3. **normalize 路径的局部流水化收益很有限**，应转向系统级 overlap 优化。

因此，若把这些实验结果映射回主线 RTL，下一步最合理的实施顺序是：

1. 先改 `fa_online_softmax_pair`；
2. 再重构 `fa_qk_dotprod_slice`；
3. 最后结合 normalize/writeback 做整行级 overlap。
