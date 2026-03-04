# 2026-03-04 基于赛题约束的 cmodel 可行优化结论

## 1. 问题澄清

- 分级误差中的 `acc` **不是** Dot-product 累加。
- 对应关系：
  - `dot`：`Q·K` 的点积累加（Dot-product 累加）
  - `acc`：在线 softmax 后的加权值累加（`acc <- acc*exp_old + exp_new*V`）

本次定位结果显示主导误差来自 `acc` 阶段，而非 `dot`。

---

## 2. 对照 problem 要求后的可优化空间

依据 `problem.md` 约束（定点输入/输出、禁止存储 SxS、在线 softmax、可使用更高位宽 softmax 路径）：

1. **允许提升中间位宽**：`Dot-product` 至少 32bit（建议 40bit+），softmax 路径允许更高位宽。
2. **允许近似函数调整**：exp/倒数近似可替换，但需说明误差来源。
3. **可配置 NEG_LARGE**：寄存器明确给出，可作为 mask 近似强度调参手段。

因此，本次优化保持在赛题要求范围内：
- 不改 RTL；
- 只在 cmodel 评估中采用更硬件可实现的高位宽定点路径；
- 输出仍为 Q8.8。

---

## 3. 本轮 cmodel 优化（不改 RTL）

新增模式：
- `fixed_hiacc_qout`
- `fixed_hiacc_real_exp_qout`

核心思路：
1. 将 `acc` 更新改为高精度定点累加（int64，等效 Q24 分数位），避免原路径在 `acc` 级联中的量化漂移。
2. `l` 保持 Q16.16 路径；最终做定点除法并量化到 Q8.8。
3. real-exp 路径下将下溢截断区间扩展（`x < -16`）以减轻 causal neg-mask 泄漏。
4. 保留在线 softmax 与 tiled 流程，不引入全矩阵存储。

---

## 4. 误差门限达标结果（MAE<=0.03, MaxAE<=0.10）

### 4.1 调优配置

推荐配置（cmodel 验证）：
- 模式：`fixed_hiacc_real_exp_qout`
- `NEG_LARGE=-8192`（Q8.8，即 -32）
- `mask_mode=neg`

### 4.2 结果摘要（5 seeds）

1) `small-int + causal + neg(mask=-32)`
- 数据：`docs/data/20260304_solution_compare_smallint_causal_neg32.csv`
- `fixed_hiacc_real_exp_qout`：
  - `MAE(mean)=0.000975`
  - `MaxAE(worst)=0.002073`
- **PASS**

2) `gaussian + causal + neg(mask=-32)`
- 数据：`docs/data/20260304_solution_compare_gaussian_causal_neg32.csv`
- `fixed_hiacc_real_exp_qout`：
  - `MAE(mean)=0.000991`
  - `MaxAE(worst)=0.006465`
- **PASS**

补充：
- 当 `NEG_LARGE=-8`（默认）时，gaussian+causal+neg 会出现尾部 `MaxAE` 失败；
- 将 `NEG_LARGE` 调整为 `-32` 可稳定压制该尾部误差，并保持完全在赛题给定寄存器/定点框架内。

---

## 5. 复现命令

```bash
cd cmodel
make build
make run-solution-compare-tuned
```

单独命令：
```bash
cd cmodel
build/attention_cmodel --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode gaussian --mask-mode neg --neg-large-q8_8 -8192 --seed 20260303 --n-seeds 5 --csv-out ../docs/data/20260304_solution_compare_gaussian_causal_neg32.csv
```

---

## 6. 结论

在不修改 RTL 的前提下，基于赛题允许的“高位宽 softmax 路径 + NEG_LARGE 可配”空间，cmodel 已得到可行优化配置，并实现 `mean_abs_error` 与 `max_abs_error` 双门限通过。