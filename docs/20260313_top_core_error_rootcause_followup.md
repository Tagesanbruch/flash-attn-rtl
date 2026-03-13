# 2026-03-13 Top-Core 误差根因跟进（BF16）

## 1) cocotb MAE/MaxAE 导出格式统一

本次已统一相关 cocotb 输出口径为与 cmodel 一致的字段命名和小数位：

- 字段名：`MAE` / `MaxAE`
- 数值格式：固定 `%.6f`

涉及文件：

- `experiments/bf16/fa_fp32_add/tb/test_fa_fp32_add.py`
- `experiments/bf16/fa_fp32_mul_q16/tb/test_fa_fp32_mul_q16.py`
- `experiments/bf16/fa_fp32_exp2_pwl/tb/test_fa_fp32_exp2_pwl.py`
- `experiments/bf16/fa_fp32_recip/tb/test_fa_fp32_recip.py`
- `experiments/bf16/fa_fp32_to_bf16/tb/test_fa_fp32_to_bf16.py`
- `experiments/bf16/fa_bf16_to_fp32/tb/test_fa_bf16_to_fp32.py`
- `experiments/bf16/fa_attention_core_bf16fp32/tb/test_fa_attention_core_bf16fp32.py`

并同步更新了汇总脚本：

- `scripts/run_bf16_module_ae_compare.py`

## 2) 模块级对照（seed=20260303）

日志与汇总在：`logs/bf16_module_ae/`

- `rtl_vs_cmodel_seed20260303.md`
- `rtl_vs_cmodel_seed20260303.csv`

结果：

- 6 个基础模块 RTL vs cmodel：`mismatches=0, MAE=0.000000, MaxAE=0.000000`
- `fp32_to_bf16` 额外量化误差（输入FP32 vs 输出重构FP32）：
  - `MAE_quant=0.010605`
  - `MaxAE_quant=0.031249`

## 3) top-core 当前失败现象

来自 `logs/bf16fp32_core.log`：

- noncausal：`MAE=0.016178, MaxAE=0.094727`
- causal：`MAE=0.018517, MaxAE=0.185547`
- 但周期一致：`cycles=8573025 expected_cycles=8573025`

说明：功能/调度主流程可跑通，主要是数值误差口径或数值路径差异。

## 4) 根因定位（当前结论）

### 4.1 关键证据 A：基础算子与 RTL 一致

基础算子模块对 cmodel 全部 `MAE=0`，排除“算子实现错误”作为主因。

### 4.2 关键证据 B：softmax_update_scalar 子模块误差远小于 top-core

新增量化输出（`logs/bf16_module_ae/fa_fp32_softmax_update_scalar_seed20260312.log`）：

- `softmax_update_scalar_exp_old_ae`: `MAE=0.000053 MaxAE=0.001369`
- `softmax_update_scalar_exp_new_ae`: `MAE=0.000060 MaxAE=0.001436`
- `softmax_update_scalar_l_ae`: `MAE=0.000274 MaxAE=0.009610`
- `softmax_update_scalar_acc_ae`: `MAE=0.000333 MaxAE=0.008007`
- `softmax_update_scalar_inv_ae`: `MAE=0.000075 MaxAE=0.018863`

子模块局部误差在 `1e-4 ~ 1e-3` 量级，不足以直接解释 top-core `~1e-2` MAE，提示“参考模型口径偏差 + 全流程累积”更可能。

### 4.3 关键证据 C：top-core cocotb reference 非完全 RTL-bit-accurate

`experiments/bf16/common/golden_models.py` 中 `attention_bf16_fp32_reference()` 依赖 `online_softmax_fp32_step()`，其内部：

- `exp` 使用 `2**x`（`_pow2_bits`）而非 `fa_fp32_exp2_pwl` 同款 PWL近似
- `l/acc` 多处使用 `float` 乘法路径而非统一 `fp32_mul_q16_bits`
- `inv_l` 使用精确 `1.0/l` 而非 `fa_fp32_recip` 同款近似

这些与 RTL 数值路径并不完全同构，会在长序列（S=256）中累计放大，导致 top-core 断言阈值 (`MAE<=2.5e-4`) 明显偏紧。

## 5) 建议的下一步

1. 在 top-core test 中引入“RTL-bit-accurate golden”（调用 `cmodel_ref` 导出的 `fp32_exp2_pwl/fp32_recip/fp32_mul_q16` 路径），替换当前混合精度 reference。
2. 在同一组 seed 下，双轨输出：
   - `rtl vs current_python_reference`
   - `rtl vs rtl_bitaccurate_reference`
3. 将门限拆分为：
   - 一致性阈值（bit-accurate 路径，接近0）
   - 算法近似阈值（系统级，允许更大）

---

当前阶段结论：**top-core 高 MAE 更可能是 reference 口径与 RTL 数值路径不一致导致，而非基础算子 RTL 偏差。**

## 6) 本轮“bit-accurate reference”改造与复测结果

已完成改造：

- `experiments/bf16/common/golden_models.py`
   - 新增 cmodel-backed bit-accurate 路径（`add/mul_q16/exp2_pwl/recip`）
   - `attention_bf16_fp32_reference(..., bitaccurate=True)` 可走该路径
- `experiments/bf16/fa_attention_core_bf16fp32/tb/test_fa_attention_core_bf16fp32.py`
   - top-core reference 改为 `bitaccurate=True`
   - 新增逐点误差 CSV 导出与 worst-point 打印

复测日志：

- `logs/bf16_module_ae/fa_attention_core_noncausal_bitaccurate_ref.log`

复测结论（noncausal）：

- 改造前：`MAE≈0.016178`
- 改造后：`MAE=0.016175, MaxAE=0.094727`（变化极小）

说明仅替换 reference 算子路径并不能消除主误差，top-core 偏差并非单点来自 `exp2/recip` 口径差。

## 7) 新增证据：逐点误差分布

逐点 CSV：

- `logs/bf16_module_ae/fa_attention_core_bf16fp32_seed20260312_noncausal.csv`

从日志提取的 worst-point：

- `i=220, j=35, ae=0.094727, got=0x3d740000, ref=0xbd100000`

统计（对该 CSV 计算）：

- 总点数：16384
- 非零异号点约：2519（约 15.37%）
- `AE > 0.05` 点数：434

这类分布更像是“系统级累计/状态演化路径差异”而不是“单个基础算子误差”。

## 8) 深挖状态演化差异（按 (q,k) 追踪 m/l/inv）

新增 trace 用例：

- `test_attention_core_trace_first_divergence`（位于 `experiments/bf16/fa_attention_core_bf16fp32/tb/test_fa_attention_core_bf16fp32.py`）
- 在每次 `S_SCORE_APPLY` 时比较 RTL 内部 `m_new/l_new/inv_l_new` 与 bit-accurate reference。

日志：

- noncausal: `logs/bf16_module_ae/fa_attention_core_trace_noncausal.log`
- causal: `logs/bf16_module_ae/fa_attention_core_trace_causal.log`

结果摘要：

- noncausal
   - `trace_first_divergence: q=0 k=128, m_ae=0.000000, l_ae=0.014572, inv_ae=0.000000`
   - `trace_summary: max_m_ae=2.950195, max_l_ae=126.247101, max_inv_ae=0.510712`
- causal
   - `trace_first_divergence: q=128 k=0, m_ae=3.224609, l_ae=0.000000, inv_ae=0.000000`
   - `trace_summary: max_m_ae=3.224609, max_l_ae=118.017960, max_inv_ae=0.464691`

解释：

- 分叉点集中在 tile 边界切换位置（`k=128` 或 `q=128`），提示问题更接近“跨 tile 状态衔接/演化一致性”，而不是单个算子近似误差。
