# BF16 experiments

本目录集中放置 Bonus 1 第一阶段的 BF16 组件实验。

此外，共享 golden 路径工具位于：

- `common/golden_models.py`
- `common/check_golden_models.py`

当前包含：

- `fa_bf16_to_fp32`
- `fa_bf16_mul_prealign`
- `fa_bf16_mul_norm_fp32`
- `fa_fp32_to_bf16`
- `fa_bf16_mul_lane`
- `fa_fp32_accum`
- `fa_fp32_max_compare`
- `fa_fp32_recip`
- `fa_fp32_exp2_pwl`
- `fa_bf16_dotprod_lane`
- `fa_fp32_softmax_update_scalar`
- `fa_fp32_softmax_row`
- `fa_attention_core_bf16fp32`

其中 `fa_attention_core_bf16fp32` 的 RTL 默认参数已对齐赛题基线 `S=256, D=64, TQ=32, TK=64`；
日常快速回归可通过参数覆盖切换到小尺寸，例如：

- `PARAM_SEQ_LEN=32 PARAM_D=8 PARAM_TQ=8 PARAM_TK=8 make verif MOD=bf16/fa_attention_core_bf16fp32 EXP=base COMPILE_ARGS='-GSEQ_LEN=32 -GD=8 -GTQ=8 -GTK=8'`

运行示例：

- `make verif MOD=bf16/fa_fp32_to_bf16 EXP=base`
- `make verif MOD=bf16/fa_bf16_mul_lane EXP=base`
- `make verif MOD=bf16/fa_fp32_accum EXP=base`
- `make verif MOD=bf16/fa_fp32_recip EXP=base`
- `make verif MOD=bf16/fa_bf16_dotprod_lane EXP=base`
- `make verif MOD=bf16/fa_fp32_softmax_update_scalar EXP=base`
- `make verif MOD=bf16/fa_fp32_softmax_row EXP=base`
- `make verif MOD=bf16/fa_attention_core_bf16fp32 EXP=base`
