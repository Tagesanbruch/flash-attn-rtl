# 20260304 精度问题溯源与 cmodel 实验记录

## 1. 目标与结论摘要

本次工作分两部分：

1. 回溯“此前可达误差门限”的验证链路，并复跑确认。
2. 在 `cmodel/` 新建 C++ 工程，构建与 RTL 同构的近似计算模型，做系统定位并评估与 FP32 的收敛情况。

核心结论：

- **此前达标（MAE~2.6e-4）来自 Python 浮点在线模型 vs PyTorch，不是 RTL 同构定点流水。**
- **RTL 同构定点模型在非因果模式下与纯 Verilator C++ TB 一致，MAE 约 0.96、MaxAE 约 3.17，未达门限。**
- **因果模式误差进一步显著恶化（MAE~1.82，MaxAE~30，small-int 输入），关键原因是 `NEG_LARGE=-8.0` 掩码抑制不足。**

---

## 2. 历史链路回溯与复跑

### 2.1 历史脚本语义

- `dv/python/torch_compare.py`
  - 使用 `ref_attention.online_row_attention_q8_8`
  - 该函数行为为：
    - 输入先量化到 Q8.8 再反量化为 float；
    - softmax / exp / 归一化仍在浮点域执行；
    - 不包含 RTL 中的 PWL exp、Q1.15/Q16.16、移位截断链路。
- `dv/python/algorithm_audit.py`
  - `online_exact` 与 `direct_softmax` 的数学等价性检查；
  - `rtl_like` 名称上虽写“rtl-like”，本质依赖上述 float 路径。

### 2.2 复跑命令与结果

- 命令：
  - `python dv/python/torch_compare.py --s 256 --d 64 --causal --n-seeds 5 --seed 20260303 --csv-out docs/data/20260304_torch_compare_s256d64_rerun.csv`
  - `python dv/python/algorithm_audit.py --seeds 5 --out docs/data/20260304_algorithm_audit_rerun.csv`
- 结果：
  - `torch_compare` worst: `MAE=0.000264, MaxAE=0.005044`（门限通过）
  - `algorithm_audit` online_exact vs direct: MaxAE ~ `4.77e-7`

结论：这条链路验证的是**算法级浮点一致性**，不是 RTL 同构精度。

---

## 3. 新建 cmodel C++ 工程

### 3.1 新增文件

- `cmodel/csrc/attention_cmodel.cpp`
- `cmodel/Makefile`（由空文件完善）

### 3.2 工程能力

`attention_cmodel.cpp` 支持以下模式（均以量化输入作为起点）：

- `rtl_exact`：严格仿 RTL 定点链（PWL exp + NR reciprocal + 固定移位）
- `rtl_real_exp`：仅将 exp 换为 real exp（其余保持定点链）
- `rtl_real_exp_float_norm`：exp=real + 浮点归一化
- `float_online_q8`：在线流程但保持 Q8 输入/输出量化边界

Makefile 目标：

- `make run`：small-int + causal
- `make run-noncausal`：small-int + non-causal
- `make run-gaussian`：gaussian + causal
- `make run-gaussian-noncausal`：gaussian + non-causal
- `make sweep`：全量跑完

---

## 4. 第 1 轮定位：输入分布影响

### 4.1 small-int（匹配当前 RTL TB 激励，值域 [-32,31]）

- **non-causal**：
  - `rtl_exact`: MAE(mean)=`0.960795`, MaxAE(worst)=`3.167275`
- **causal**：
  - `rtl_exact`: MAE(mean)=`1.821791`, MaxAE(worst)=`30.560544`

### 4.2 gaussian（N(0,1) 后量化）

- **non-causal**：
  - `rtl_exact`: MAE(mean)=`20.350456`, MaxAE(worst)=`127.440869`
- **causal**：
  - `rtl_exact`: MAE(mean)=`33.104080`, MaxAE(worst)=`127.525699`

结论：

- 输入幅值越大，定点链饱和越严重，误差爆发。
- 因果模式在现有 `NEG_LARGE=-8.0` 下会额外放大误差。

---

## 5. 第 2 轮定位：算子级误差归因

在 small-int + non-causal 条件下对比：

- `rtl_exact`: MAE `0.960795`
- `rtl_real_exp`: MAE `0.960408`
- `rtl_real_exp_float_norm`: MAE `0.961714`

观察：

- 将 PWL exp 替换为 real exp 改善极小（约 `3.9e-4`）。
- 说明**主误差不在 exp 分段近似本身**，而在更上游/全链路的定点尺度耦合（累加尺度、归一化尺度、截断与饱和策略）。

另一个关键观察：

- causal 模式误差明显高于 non-causal（尤其 MaxAE），与 `NEG_LARGE` 取值偏弱高度相关。

---

## 6. 与纯 Verilator C++ TB 的对齐关系

纯 Verilator C++ TB（`make check-sdpa-verilator-cpp`）给出：

- `RTL vs FP32`: MAE=`0.976112`, MaxAE=`2.856000`（non-causal）

与 `cmodel` small-int + non-causal 的 `rtl_exact`（MAE~0.96, MaxAE~3.17）处于同一量级，趋势一致。

---

## 7. 当前问题清单（需继续收敛）

1. **FP32 门限未达标**：在 RTL 同构链路下误差远超 `0.03/0.10`。
2. **causal mask 数值策略偏弱**：`NEG_LARGE=-8.0` 在 `S=256` 下抑制不足。
3. **输入动态范围敏感**：高斯分布下大量输出饱和到 Q8.8 极值。

---

## 8. 建议下一步（可执行）

1. 在 RTL 与 cmodel 中同步试验更强 mask：`NEG_LARGE` 由 `-8` 扩到 `-16/-24`（或使用条件硬屏蔽）。
2. 输出链路增加尺度审计：逐行记录 `row_l`、`row_acc` 的统计区间，确认溢出热点。
3. 细化定点预算：对 `acc` 到 `O` 的归一化路径尝试更高内部精度和延迟截断。
4. 固化双口径验证：
   - 算法口径（float online vs torch）
   - 实现口径（rtl_exact vs fp32）

---

## 9. 20260304 加做：Causal mask 与 NEG_LARGE 扫描定位

本轮新增 sweep（small-int 输入，5 seeds）：

- `mask_mode=neg, NEG_LARGE=-8/-16/-24/-32`
- `mask_mode=hard`（直接跳过 `j>i`）

结果（`rtl_exact`）：

- `neg` 模式所有 `NEG_LARGE` 档位结果**完全一致**：
  - `MAE(mean)=1.821791`, `MaxAE(worst)=30.560544`
- `hard` 模式略差：
  - `MAE(mean)=1.835781`, `MaxAE(worst)=31.878906`

结论：

1. **仅调 NEG_LARGE 无效**：因为当前 exp 路径对输入下限做了 `-8.0` 截断，`score-m` 小于该值后都映射到同一段，导致 `-8/-16/-24/-32` 在实现上“等价”。
2. **误差热点在早期行（row 0/1）**：worst 点持续出现在低行号，说明 causal 下 `l/acc` 小分母区间的定点误差放大是主因。
3. **hard mask 不是银弹**：跳过 masked token 后仍未改善，说明核心问题在归一化尺度与定点更新链，而非单一 mask 注入方式。

---

## 10. 新增复现命令（工程化）

```bash
# cmodel 全量模式实验
make cmodel-sweep

# cmodel 仅跑 causal mask/NEG_LARGE 扫描
make cmodel-mask-sweep
```

---

## 11. 产物索引

- `docs/data/20260304_torch_compare_s256d64_rerun.csv`
- `docs/data/20260304_algorithm_audit_rerun.csv`
- `docs/data/20260304_cmodel_modes_s256d64_causal.csv`
- `docs/data/20260304_cmodel_modes_s256d64_noncausal.csv`
- `docs/data/20260304_cmodel_modes_s256d64_causal_gaussian.csv`
- `docs/data/20260304_cmodel_modes_s256d64_noncausal_gaussian.csv`
- `docs/data/20260304_cmodel_mask_sweep_neg8.csv`
- `docs/data/20260304_cmodel_mask_sweep_neg16.csv`
- `docs/data/20260304_cmodel_mask_sweep_neg24.csv`
- `docs/data/20260304_cmodel_mask_sweep_neg32.csv`
- `docs/data/20260304_cmodel_mask_sweep_hard.csv`
