# 2026-03-15 FP8 Attention Core 最小可跑路径实现报告

## 1. 目标

按本轮选择项，先搭建 FP8 attention core 最小可跑路径：

1. QK score 计算；
2. softmax prep（最小近似链路）；
3. PV accum 输出 context。

说明：本版是功能闭环版本，目标是“可跑可验”，不是最终精度/性能最优实现。

## 2. 新增组件

### 2.1 softmax prep 最小组件

- `experiments/fp8/fa_fp8_softmax_prep_min/base/fa_fp8_softmax_prep_min.sv`

实现：

1. 输入 `score_q8_11`；
2. 近似 `exp2`：通过移位映射到 `Q0.15` 权重；
3. 输出 `weight_q0_15`。

### 2.2 PV 累加组件

- `experiments/fp8/fa_fp8_pv_accum8/base/fa_fp8_pv_accum8.sv`

实现：

1. `V` 向量 FP8(E4M3) -> Q4.11；
2. 与 `weight_q0_15` 相乘后累加；
3. 输出 `ctx_q4_11`。

### 2.3 attention core 最小路径

- `experiments/fp8/fa_fp8_attention_core_min/base/fa_fp8_attention_core_min.sv`

输入：

- `i_q_vec/i_k_vec/i_v_vec`（各 8xFP8）
- `i_score_scale_q1_14`
- `i_round_mode`
- `i_saturate_en`

输出：

- `o_score_q8_11`
- `o_weight_q0_15`
- `o_ctx_q4_11`

## 3. 验证

测试文件：

- `experiments/fp8/fa_fp8_attention_core_min/tb/test_fa_fp8_attention_core_min.py`

命令：

```bash
make -C experiments verif MOD=fp8/fa_fp8_attention_core_min EXP=base
```

结果：

- `samples=2000`
- `mismatches=0`
- `score_mis=0`
- `weight_mis=0`
- `ctx_mis=0`

## 4. 调试过程与修复点

### 4.1 初版失败现象

首次回归失败：`mismatches=911/2000`。

### 4.2 根因定位

通过分段统计定位到：

1. `score` 一致；
2. 主要偏差在 `weight` 与 `ctx`。

根因：

1. softmax prep 阶段把 `score_q8_3` 压成 8 位，负大数被截断后误判为正值；
2. scale 中间乘积位宽不足导致溢出风险。

### 4.3 修复

1. `score_q8_3` 扩为 32 位，保持符号与量级；
2. score scale 中间值扩到 56 位并在最终阶段饱和；
3. softmax 负向移位使用显式 `neg_shift`，避免位切片导致的语义偏差。

## 5. 当前结论

1. FP8 attention core 最小数据路径已可运行并通过回归；
2. 现有链路可作为后续 tile 化、流水化和控制面接线的基础版本；
3. 下一步可在不改动接口的前提下替换 softmax 近似与多 token 归一化路径。
