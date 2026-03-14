# 2026-03-15 FP8 数值策略与 MMA 组件扩展报告

## 1. 目标与范围

根据本轮指令，完成两件事：

1. 补齐 FP8 数值策略与 corner case；
2. 以 FP8 为基础，先实现 attention core 下游可复用组件，并引入 MMA 微接口骨架。

本次属于组件层 bootstrap，不是完整 FP8 attention core 端到端替换。

## 2. 新增模块

### 2.1 数值策略模块

- `experiments/fp8/fa_fp8_e4m3_to_fixed16_cfg/base/fa_fp8_e4m3_to_fixed16_cfg.sv`

能力：

1. E4M3 -> fixed16（默认语义对齐 Q4.11）；
2. `i_round_mode`：`0` 截断，`1` 近似四舍五入（away-from-zero）；
3. `i_saturate_en`：饱和开关；
4. `i_out_frac_bits`：可配置输出小数位（0~11）；
5. `o_is_nan/o_is_inf/o_is_zero`：corner flag 输出。

### 2.2 MMA 微接口骨架

- `experiments/fp8/fa_fp8_mma_uop_engine/base/fa_fp8_mma_uop_engine.sv`

接口特征：

1. `i_valid/o_ready` 与 `o_valid/i_ready` 双向握手；
2. 输入包含 `a_fp8/b_fp8 + acc_q8_11 + scale_q1_14`；
3. 支持 rounding/saturate 控制；
4. 输出 `o_res_q8_11`，适合作为后续 tile/阵列的 lane 级算子。

### 2.3 QK 点积组件

- `experiments/fp8/fa_fp8_qk_mma8/base/fa_fp8_qk_mma8.sv`

能力：

1. 8 路 FP8(Q/K) 点积；
2. 输出 Q8.11 score；
3. 支持 rounding/saturate 控制。

## 3. 新增测试

- `experiments/fp8/fa_fp8_e4m3_to_fixed16_cfg/tb/test_fa_fp8_e4m3_to_fixed16_cfg.py`
  - 随机测试 + corner vectors（Zero/Inf/NaN/Subnormal/极值）
- `experiments/fp8/fa_fp8_mma_uop_engine/tb/test_fa_fp8_mma_uop_engine.py`
  - 随机流测试（握手流）
- `experiments/fp8/fa_fp8_qk_mma8/tb/test_fa_fp8_qk_mma8.py`
  - 随机 8 路 QK 点积一致性

## 4. 回归命令与结果

执行：

```bash
make -C experiments verif MOD=fp8/fa_fp8_e4m3_to_fixed16_cfg EXP=base
make -C experiments verif MOD=fp8/fa_fp8_qk_mma8 EXP=base
make -C experiments verif MOD=fp8/fa_fp8_mma_uop_engine EXP=base
```

结果：

1. `fa_fp8_e4m3_to_fixed16_cfg`：PASS，`tests=2`, `FAIL=0`；
2. `fa_fp8_qk_mma8`：PASS，`samples=4000`, `mismatches=0`；
3. `fa_fp8_mma_uop_engine`：PASS，`sent=800`, `out=800`, `mismatches=0`。

## 5. 关键问题与修复

### 5.1 可配置转换模块 latch 告警

现象：

- Verilator 将 latch 警告升级为错误，编译失败。

根因：

- `always_comb` 中部分临时变量在特定路径未赋默认值。

修复：

- 为 `sh/rounded/quant_q/clamp_q/o_fixed` 增加统一默认赋值。

### 5.2 MMA 引擎初版 mismatch 与长时间运行

现象：

- 初版测试出现大量 mismatch，且存在运行时间偏长风险。

根因：

1. 缩放路径把 56 位乘积截成 48 位再舍入，造成数值丢失；
2. 测试握手时序过于激进，导致期望对齐困难。

修复：

1. RTL 改为全程使用 56 位缩放中间值并再右移；
2. 测试改为有界随机流（固定样本、稳定 ready），保留握手语义同时压缩运行时长。

## 6. 对 FP8 attention core 的推进意义

已具备三类可拼装基础块：

1. 格式与量化控制：`fa_fp8_e4m3_to_fixed16_cfg`；
2. QK 核心算子：`fa_fp8_qk_mma8`；
3. 可扩展握手算子：`fa_fp8_mma_uop_engine`。

下一步可在此基础上拼接：

1. 多 lane tile（QK/AV 两种 uop）；
2. score scale + softmax prep 的定点路径；
3. 与控制平面寄存器的 mode/round/sat 配置接线。
