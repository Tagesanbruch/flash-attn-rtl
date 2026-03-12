# BF16 experiments

本目录集中放置 Bonus 1 第一阶段的 BF16 组件实验。

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

运行示例：

- `make verif MOD=bf16/fa_fp32_to_bf16 EXP=base`
- `make verif MOD=bf16/fa_bf16_mul_lane EXP=base`
- `make verif MOD=bf16/fa_fp32_accum EXP=base`
- `make verif MOD=bf16/fa_fp32_recip EXP=base`
- `make verif MOD=bf16/fa_bf16_dotprod_lane EXP=base`
