# 2026-03-06 Baseline Optimization Experiment Results

## Scope

按 [docs/20260306_baseline_optimization_experiment_plan.md](docs/20260306_baseline_optimization_experiment_plan.md) 的规划，先完成 4 组 baseline-only 微结构实验，不改动主线 `fa_attention_core`，优先验证：

1. `exp` 路径能否用 base-2 LUT 近似替代
2. online softmax 更新链能否切到 base-2 形式
3. row-level surrogate 能否在 base-2 近似下保持一致建模
4. normalize 小核的并行化是否能稳定带来时延改善

## Implemented Experiment Groups

### 1. `fa_exp2_lut_q1_15`

位置：
- [experiments/fa_exp2_lut_q1_15/base/fa_exp2_lut_q1_15.sv](experiments/fa_exp2_lut_q1_15/base/fa_exp2_lut_q1_15.sv)
- [experiments/fa_exp2_lut_q1_15/exp_a/fa_exp2_lut_q1_15.sv](experiments/fa_exp2_lut_q1_15/exp_a/fa_exp2_lut_q1_15.sv)
- [experiments/fa_exp2_lut_q1_15/tb/test_fa_exp2_lut_q1_15.py](experiments/fa_exp2_lut_q1_15/tb/test_fa_exp2_lut_q1_15.py)

设计：
- 先用 `-x * log2(e)` 将 `e^x` 映射成 `2^{-z}`
- `base` 用 16 项分数 LUT
- `exp_a` 用 32 项分数 LUT
- 共同保留整数位右移实现指数衰减

验证结论：
- 两个变体均通过 monotonic + directed cocotb 测试
- 测试约束：
  - `base` 最大实数误差阈值 `< 0.09`
  - `exp_a` 最大实数误差阈值 `< 0.06`
- 说明 `exp_a` 已能作为更精细的 base-2 `exp` 候选

### 2. `fa_online_softmax_base2`

位置：
- [experiments/fa_online_softmax_base2/base/fa_online_softmax_base2.sv](experiments/fa_online_softmax_base2/base/fa_online_softmax_base2.sv)
- [experiments/fa_online_softmax_base2/exp_a/fa_online_softmax_base2.sv](experiments/fa_online_softmax_base2/exp_a/fa_online_softmax_base2.sv)
- [experiments/fa_online_softmax_base2/tb/test_fa_online_softmax_base2.py](experiments/fa_online_softmax_base2/tb/test_fa_online_softmax_base2.py)

设计：
- 保持原 online recurrence 结构
- 仅将 `exp(diff)` 替换为 base-2 LUT 近似
- `base/exp_a` 分别对应 16/32 项 LUT

验证结论：
- 两个变体均通过单行与多行随机测试
- RTL 输出与 Python base-2 参考模型逐拍完全一致
- 说明替换 `exp` 后，在线更新链可稳定工作，适合继续向 row/core 级联验证

### 3. `fa_row_reduction_core_base2`

位置：
- [experiments/fa_row_reduction_core_base2/base/fa_row_reduction_core_base2.sv](experiments/fa_row_reduction_core_base2/base/fa_row_reduction_core_base2.sv)
- [experiments/fa_row_reduction_core_base2/exp_a/fa_row_reduction_core_base2.sv](experiments/fa_row_reduction_core_base2/exp_a/fa_row_reduction_core_base2.sv)
- [experiments/fa_row_reduction_core_base2/tb/test_fa_row_reduction_core_base2.py](experiments/fa_row_reduction_core_base2/tb/test_fa_row_reduction_core_base2.py)

设计：
- 用 `fa_online_softmax_base2` 替换旧行归约核中的 online softmax 更新单元
- 保留 `Q16.16` reciprocal + final normalize 路径
- 用 row-level surrogate 验证最终输出是否与软件模型匹配

验证结论：
- 两个变体均通过 directed/random row 测试
- RTL 与 Python surrogate 结果完全一致
- 这说明 base-2 近似不只停留在算子级，可闭环到 row 输出级

### 4. `fa_row_norm_vec`

位置：
- [experiments/fa_row_norm_vec/base/fa_row_norm_vec.sv](experiments/fa_row_norm_vec/base/fa_row_norm_vec.sv)
- [experiments/fa_row_norm_vec/exp_a/fa_row_norm_vec.sv](experiments/fa_row_norm_vec/exp_a/fa_row_norm_vec.sv)
- [experiments/fa_row_norm_vec/tb/test_fa_row_norm_vec.py](experiments/fa_row_norm_vec/tb/test_fa_row_norm_vec.py)

设计：
- 独立抽出 row normalize 小核
- `base`：4-lane/两段处理
- `exp_a`：8-lane/单段处理
- 输出仍是饱和到 `Q8.8`

验证结论：
- 两个变体均通过随机和定向测试
- 在当前寄存化实现下，从输入采样到 `o_valid` 观测延迟为：
  - `base`: 3 cycles
  - `exp_a`: 2 cycles
- 这验证了 normalize 小核并行化的低风险收益方向

## Makefile Support

为保证新实验能自动走 clocked STA/verification 流，已更新：
- [experiments/Makefile](experiments/Makefile)

新增 clocked 模块：
- `fa_online_softmax_base2`
- `fa_row_reduction_core_base2`
- `fa_row_norm_vec`

## Verification Summary

已完成：
- `make lint` / `make verif` for
  - `fa_exp2_lut_q1_15` `base`
  - `fa_exp2_lut_q1_15` `exp_a`
  - `fa_online_softmax_base2` `base`
  - `fa_online_softmax_base2` `exp_a`
  - `fa_row_reduction_core_base2` `base`
  - `fa_row_reduction_core_base2` `exp_a`
  - `fa_row_norm_vec` `base`
  - `fa_row_norm_vec` `exp_a`

当前状态：
- 全部 lint 通过
- 全部 cocotb 通过

## Synthesis / STA Summary

本轮已对 8 个新实验变体补做 `make sta CLK_FREQ_MHZ=500`，产物位于 `syn/exp_*_20260306/`。

代表性报告位置：
- [exp2 LUT exp_a synth](syn/exp_fa_exp2_lut_q1_15_exp_a_20260306/fa_exp2_lut_q1_15-500MHz/synth_stat.txt)
- [exp2 LUT exp_a sta](syn/exp_fa_exp2_lut_q1_15_exp_a_20260306/fa_exp2_lut_q1_15-500MHz/sta.log)
- [online softmax base2 exp_a synth](syn/exp_fa_online_softmax_base2_exp_a_20260306/fa_online_softmax_base2-500MHz/synth_stat.txt)
- [online softmax base2 exp_a sta](syn/exp_fa_online_softmax_base2_exp_a_20260306/fa_online_softmax_base2-500MHz/sta.log)
- [row reduction base2 exp_a synth](syn/exp_fa_row_reduction_core_base2_exp_a_20260306/fa_row_reduction_core_base2-500MHz/synth_stat.txt)
- [row reduction base2 exp_a sta](syn/exp_fa_row_reduction_core_base2_exp_a_20260306/fa_row_reduction_core_base2-500MHz/sta.log)
- [row norm vec exp_a synth](syn/exp_fa_row_norm_vec_exp_a_20260306/fa_row_norm_vec-500MHz/synth_stat.txt)
- [row norm vec exp_a sta](syn/exp_fa_row_norm_vec_exp_a_20260306/fa_row_norm_vec-500MHz/sta.log)

用于对比的旧参考报告：
- [old exp pwl pipe exp_b](syn/exp_fa_exp_pwl_8seg_q1_15_pipe_exp_b_20260306/fa_exp_pwl_8seg_q1_15_pipe-500MHz/sta.log)
- [old online softmax update](syn/fa_online_softmax_update_20260306_r0306/fa_online_softmax_update-500MHz/sta.log)
- [old row reduction core](syn/fa_row_reduction_core_20260306/fa_row_reduction_core-500MHz/sta.log)

### STA table @ 500MHz

| Module | Area | Worst Slack | Report Freq | 500MHz |
| --- | ---: | ---: | ---: | --- |
| `fa_exp2_lut_q1_15/base` | 1575.00 | 0.152ns | 541.163MHz | Pass |
| `fa_exp2_lut_q1_15/exp_a` | 1445.92 | 0.181ns | 549.615MHz | Pass |
| `fa_online_softmax_base2/base` | 20719.16 | -2.756ns | 210.268MHz | Fail |
| `fa_online_softmax_base2/exp_a` | 21078.12 | -2.860ns | 205.747MHz | Fail |
| `fa_row_reduction_core_base2/base` | 41738.76 | -12.135ns | 70.746MHz | Fail |
| `fa_row_reduction_core_base2/exp_a` | 42871.92 | -12.212ns | 70.361MHz | Fail |
| `fa_row_norm_vec/base` | 88718.00 | -0.660ns | 375.928MHz | Fail |
| `fa_row_norm_vec/exp_a` | 90376.44 | -0.527ns | 395.715MHz | Fail |

### Reference table @ 500MHz

| Reference | Area | Worst Slack | Report Freq | 500MHz |
| --- | ---: | ---: | ---: | --- |
| `fa_exp_pwl_8seg_q1_15_pipe/exp_b` | 3178.84 | 0.524ns | 677.389MHz | Pass |
| `fa_online_softmax_update` | 22217.72 | -3.276ns | 189.545MHz | Fail |
| `fa_row_reduction_core` | 89867.40 | -3.294ns | 188.901MHz | Fail |

### STA findings

1. `fa_exp2_lut_q1_15` 两个版本都通过 500MHz，且面积明显小于旧 `fa_exp_pwl_8seg_q1_15_pipe/exp_b`。
  - `base` 面积约下降 50.5%
  - `exp_a` 面积约下降 54.5%
2. `fa_exp2_lut_q1_15/exp_a` 是本轮最好的 `exp` 候选：面积比 `base` 再低，slack 也更高。
3. `fa_online_softmax_base2` 相对旧 `fa_online_softmax_update` 有一定改善：
  - 面积下降约 5%~7%
  - 报告频率从约 189.5MHz 提高到约 206~210MHz
  - 但距离 500MHz 仍很远，当前不能直接主线替换。
4. `fa_online_softmax_base2/exp_a` 相比 `base` 没有带来 STA 收益，反而略增面积、略降频。
5. `fa_row_reduction_core_base2` 面积虽然较旧 `fa_row_reduction_core` 下降超过 50%，但时序严重恶化到约 70MHz，说明当前 base-2 row surrogate 更像功能验证平台，而不是可直接综合落地主线的结构。
6. `fa_row_norm_vec` 是本轮最接近可工程化推进的次优候选：
  - `exp_a` 相比 `base` 仅增加约 1.9% 面积
  - 报告频率从 375.9MHz 提升到 395.7MHz
  - 仍未过 500MHz，但离目标明显比 `online_softmax_base2`/`row_reduction_core_base2` 更近。

## Interim Recommendation

当前更值得继续推进到主线评估的是：

1. `fa_exp2_lut_q1_15/exp_a`
  - 精度相对更稳
  - 500MHz STA 通过
  - 面积显著优于旧 `fa_exp_pwl_8seg_q1_15_pipe`
2. `fa_row_norm_vec/exp_a`
  - 风险低
  - 对 normalize 段有直接周期收益
  - 当前约 395.7MHz，是最接近继续打磨到 500MHz 的结构
3. `fa_online_softmax_base2/base`
  - 已完成逐拍模型闭环
  - 相对旧 `fa_online_softmax_update` 有小幅面积/时序改善
  - 但在进入主线前必须先做进一步 pipeline 拆分

`fa_row_reduction_core_base2` 当前更适合作为中间闭环验证平台，而不是直接主线替换件。

## Next Step

下一步建议：

1. 先把 `fa_exp2_lut_q1_15/exp_a` 作为唯一已经通过 500MHz 的新算子候选，接入更接近主线的 `exp` 局部路径做替换验证。
2. 对 `fa_row_norm_vec/exp_a` 做一次小幅 pipeline/retime 版本，目标先冲过 500MHz，再评估是否替换主线 normalize 循环。
3. 对 `fa_online_softmax_base2` 先不要直接并入主线；应先做 stage 切分，把 `max / diff / exp / l,acc update` 再拆成更多寄存级，再重新做模块 STA。
4. `fa_row_reduction_core_base2` 保留为功能闭环平台，不再作为近期主线集成候选。
