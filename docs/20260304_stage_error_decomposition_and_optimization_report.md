# 2026-03-04 分级误差分解与优化实验报告

## 1. 目标

在现有 `cmodel` 模块化基础上，完成以下工作：

1. 新增“逐级误差分解”输出（`dot / score / exp / l / acc / norm`），定位主导误差阶段。
2. 基于定位结果提出并实现优化方案，进行多场景实验。
3. 评估是否达到门限目标：`MAE <= 0.03` 且 `MaxAE <= 0.10`。
4. 输出可复现命令与对比数据（`docs/data/*.csv`）。

---

## 2. 代码改动摘要

### 2.1 新增能力

- 在 `cmodel` 参数中新增：
  - `--run-stage-decomp`
  - `--stage-seed`
  - `--stage-csv-out`
- 新增 stage 分解接口与数据结构：
  - `StageMetrics`
  - `StageDecompResult`
- 新增优化模式：
  - `acc_float_qout`
  - `acc_float_real_exp_qout`
  - 保留上界参考：`fp32_then_q8`

### 2.2 功能模块现状

- 数学工具：`cmodel/csrc/attention_math.cpp`
- 计算内核：`cmodel/csrc/attention_kernels.cpp`
- 实验与分解：`cmodel/csrc/attention_experiment.cpp`
- 主流程汇总：`cmodel/csrc/attention_lib.cpp`
- 公共接口：`cmodel/csrc/attention_core.hpp`

### 2.3 可复现目标

`cmodel/Makefile` 新增：

- `run-stage-decomp`
- `run-solution-compare`

---

## 3. 逐级误差分解结果

### 3.1 small-int + causal（seed=20260303）

数据文件：
- `docs/data/20260304_stage_decomp_smallint_causal.csv`

关键结果：
- `dot`: MAE=0.001939
- `score`: MAE=0.001196
- `exp`: MAE=0.000798
- `l`: MAE=0.127709
- `acc`: MAE=135.584676
- `norm`: MAE=1.864973

结论：
- **主导误差阶段为 `acc`**（远高于其他阶段）。

### 3.2 gaussian + causal（seed=20260303）

数据文件：
- `docs/data/20260304_stage_decomp_gaussian_causal.csv`

关键结果：
- `dot`: MAE=0.001946
- `score`: MAE=0.001222
- `exp`: MAE=0.003765
- `l`: MAE=1.566671
- `acc`: MAE=464.112069
- `norm`: MAE=33.436191

结论：
- **主导误差阶段仍为 `acc`**，且在高动态输入（gaussian）下更严重。

---

## 4. 方案与优化实验

### 4.1 方案定义

- `rtl_exact`：原始 RTL-like 路径（基线）
- `rtl_real_exp`：仅替换 real-exp
- `rtl_real_exp_float_norm`：real-exp + float norm
- `float_online_q8`：在线过程近似浮点对照
- `acc_float_qout`：保持量化打分/指数，`acc/l` 使用 float，输出量化
- `acc_float_real_exp_qout`：在上一步基础上，`exp` 改 real-exp
- `fp32_then_q8`：FP32 完整计算后量化（理论上界参考）

### 4.2 多场景结果（5 seeds）

#### A) small-int + causal + mask=neg

数据文件：
- `docs/data/20260304_solution_compare_smallint_causal_neg.csv`

均值/最坏：
- `rtl_exact`: MAE=1.821791, MaxAE=30.560544（FAIL）
- `acc_float_qout`: MAE=0.001002, MaxAE=0.011719（PASS）
- `acc_float_real_exp_qout`: MAE=0.000997, MaxAE=0.011719（PASS）
- `fp32_then_q8`: MAE=0.000975, MaxAE=0.001953（PASS）

#### B) small-int + causal + mask=hard

数据文件：
- `docs/data/20260304_solution_compare_smallint_causal_hard.csv`

均值/最坏：
- `rtl_exact`: MAE=1.835781, MaxAE=31.878906（FAIL）
- `acc_float_qout`: MAE=0.000975, MaxAE=0.002060（PASS）
- `acc_float_real_exp_qout`: MAE=0.000975, MaxAE=0.002073（PASS）
- `fp32_then_q8`: MAE=0.000975, MaxAE=0.001953（PASS）

#### C) gaussian + causal + mask=neg

数据文件：
- `docs/data/20260304_solution_compare_gaussian_causal_neg.csv`

均值/最坏：
- `rtl_exact`: MAE=33.104080, MaxAE=127.525699（FAIL）
- `acc_float_qout`: MAE=0.012175, MaxAE=0.582031（**MaxAE FAIL**）
- `acc_float_real_exp_qout`: MAE=0.002454, MaxAE=0.527344（**MaxAE FAIL**）
- `fp32_then_q8`: MAE=0.000972, MaxAE=0.001953（PASS）

#### D) gaussian + causal + mask=hard

数据文件：
- `docs/data/20260304_solution_compare_gaussian_causal_hard.csv`

均值/最坏：
- `rtl_exact`: MAE=33.324375, MaxAE=127.581334（FAIL）
- `acc_float_qout`: MAE=0.010947, MaxAE=0.180741（**MaxAE FAIL**）
- `acc_float_real_exp_qout`: MAE=0.000991, MaxAE=0.006465（PASS）
- `fp32_then_q8`: MAE=0.000972, MaxAE=0.001953（PASS）

#### E) small-int + non-causal + mask=neg

数据文件：
- `docs/data/20260304_solution_compare_smallint_noncausal_neg.csv`

均值/最坏：
- `rtl_exact`: MAE=0.960795, MaxAE=3.167275（FAIL）
- `acc_float_qout`: MAE=0.000954, MaxAE=0.001977（PASS）
- `acc_float_real_exp_qout`: MAE=0.000954, MaxAE=0.001975（PASS）
- `fp32_then_q8`: MAE=0.000954, MaxAE=0.001953（PASS）

---

## 5. 结论

1. 通过分级误差分解可明确定位：**`acc` 是主导误差来源**，`dot/score/exp` 不是主要矛盾。
2. 仅替换 exp 或 norm（不提升 `acc` 精度）无法解决问题。
3. 针对 `acc` 进行精度提升后，误差显著下降并在多数场景达标。
4. 对于高动态 gaussian + causal 场景，`acc_float_real_exp_qout` 在 `mask=hard` 下可达标；`mask=neg` 下仍存在尾部 `MaxAE` 风险。
5. 若以“全场景稳妥达标”为目标，当前实验中最稳健上界是 `fp32_then_q8`；若兼顾“保留更多 RTL-like 结构”，`acc_float_real_exp_qout` 是当前最优折中。

---

## 6. 复现实验命令

在仓库根目录执行：

```bash
cd cmodel
make build
make run-stage-decomp
make run-solution-compare
```

若需单独验证 gaussian hard 场景：

```bash
cd cmodel
build/attention_cmodel --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode gaussian --mask-mode hard --seed 20260303 --n-seeds 5 --csv-out ../docs/data/20260304_solution_compare_gaussian_causal_hard.csv
```
