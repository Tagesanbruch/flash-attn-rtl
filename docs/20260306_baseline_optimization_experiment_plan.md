# 2026-03-06 Baseline 方向优化评估与实验计划

## 1. 目标与边界

本轮只做 **Baseline** 方向优化，不开展 Bonus 版本实现。原因如下：

1. 赛题要求 Bonus 必须在 Baseline 通过后以独立版本开展。
2. 当前主线虽然已经满足精度与 `<300k cycles` 基线，但顶层时序和面积仍未完全定版。
3. 当前更值得投入的方向仍是 **Baseline 的 `f_clk / cycles` 净收益**，而不是功能扩展。

同时需要持续注意赛题面积约束：

- 等效逻辑门数 $
\le 2,000,000$
- 且 **包含存储器折算**

因此，本轮实验默认遵循以下策略：

- 不通过粗暴增加并行 lane 来换周期；
- 不直接引入大规模额外阵列；
- 优先尝试 **低面积增量** 的算子/递推/局部调度优化；
- 所有实验都应兼顾 `cycles`、局部时序和面积风险。

## 2. 当前 Baseline 的主要瓶颈

根据现有统计：

- `total_cycles = 148,656`
- `Compute+Normalize+Ctrl = 111,793 cycles`
- 其中：
  - `ms_compute_cycles = 131,200`
  - `cs_dp_cycles = 98,304`
  - `cs_score_cycles = 32,768`
  - `ms_normalize_cycles = 2,056`
  - `ms_other_cycles = 15,400`

可见：

### 2.1 最大瓶颈仍是 Compute 主循环

`fa_attention_core` 当前在 [rtl/core/fa_attention_core.sv](rtl/core/fa_attention_core.sv#L551-L654) 中采用：

- 每个 `K/V tile` 顺序处理；
- 行对 (`ROW_PAR=2`) 为粒度；
- `DP_CHUNKS=2` 的 dot-product；
- 之后进入 `score -> online softmax -> PV` 更新。

从周期分布看，`cs_dp_cycles + cs_score_cycles = 131,072`，几乎占据整个计算主体。这说明：

1. dot-product 本身仍是主成本；
2. score 缩放 / softmax 更新虽然局部不算长，但被嵌入在高度串行的控制框架中；
3. 若只增加算子流水、而不改善调度，系统总周期很容易上升。

### 2.2 当前 online softmax 更新结构仍有可优化空间

当前主线在 [rtl/core/fa_attention_core.sv](rtl/core/fa_attention_core.sv#L324-L366) 中，针对每个 score 更新：

- `m` 更新；
- 通过 `fa_exp_pwl_8seg_q1_15` 计算 `exp(m_old-m_new)` 和 `exp(score-m_new)`；
- `l` 重标定；
- `acc` 做 rescale + `P*V` 累加。

这条路径的特点是：

- 算法正确；
- 组合逻辑和大宽度乘加绑定较紧；
- 很适合做 **base-2 / shift-renorm / 融合算子** 实验；
- 但不适合简单加深流水后原地等待。

### 2.3 Normalization 周期有空间，但不是一号瓶颈

[rtl/core/fa_attention_core.sv](rtl/core/fa_attention_core.sv#L655-L717) 中归一化阶段按 `NORM_LANES=8` 展开。

- 当前 `ms_normalize_cycles = 2,056`
- 占总周期比例不高

但这是一个 **低风险、可独立验证** 的优化点：

- 适度增大并行归一化 lane，可能在小面积代价下回收约千级周期；
- 同时也能为后续更高 `S` 或更多输出并行做准备。

### 2.4 `ms_other_cycles = 15,400` 暗示控制/切换气泡仍存在

这部分不算最大头，但说明：

- Q/K/V tile 切换仍存在控制空泡；
- prefetch 和 compute 的协同还有提升空间；
- 当前双 bank prefetch 机制已经存在，但尚未做到更细粒度 overlap。

不过，这一项若直接在主线动大手术，风险较高。因此本轮先通过更小粒度实验逼近：

- online softmax 局部结构优化；
- row reduction 级联模块优化；
- 归一化小模块优化；
- exp 替代算子优化。

## 3. 为什么这轮不直接做“大改主线”

尽管从论文调研看，行级双缓冲、双 FSM overlap、甚至类 systolic 融合都很有前景，但当前不建议第一步就直接改主线：

1. 主线已经有可用正确性基准；
2. 顶层 DMA / tile / control 交织较复杂；
3. 现在更需要先用模块级实验验证：
   - 误差是否可控；
   - STA 是否真实改善；
   - 面积增量是否可接受；
   - 插入主线后是否有现实可行的对接方式。

因此，本轮采取：

- **先完成文档定版**；
- **再做 4 组模块/子系统实验**；
- 所有实验通过后，再决定是否把其中一组或多组推广进主线。

## 4. 本轮确定开展的 4 组实验

### 实验组 A：`fa_exp2_lut_q1_15`

**目的**：验证 `base-2 exp2 + 小 LUT` 是否能作为 `fa_exp_pwl_8seg_q1_15` 的低成本替代。

**原因**：

- 当前 `fa_exp_pwl_8seg_q1_15` 是活动主路径未过 500MHz 的模块之一；
- 文献和现有调研都表明，base-2 形式更适合与 shift / renorm 结合；
- 该实验本身不改主线控制，易于独立验证。

**实验变体**：

- `base`：16-entry fractional LUT + integer shift
- `exp_a`：32-entry fractional LUT，提高精度

**评估项**：

- monotonic
- 与 real exp 的误差
- STA 与面积

### 实验组 B：`fa_online_softmax_base2`

**目的**：验证 base-2 online normalization 是否能降低 softmax 反馈链复杂度。

**原因**：

- 当前 `m/l/acc` 更新链是 baseline 中最自然的系统级突破口；
- 直接改主线风险过大，先做单行 update 模块实验更稳；
- 若该实验有效，可作为后续主线替换候选。

**实验变体**：

- `base`：base-2 online softmax，重标定使用 shift
- `exp_a`：fractional LUT 版，提高精度

**评估项**：

- 单行递推正确性
- 误差与稳定性
- STA 与面积

### 实验组 C：`fa_row_reduction_core_base2`

**目的**：把实验组 B 的在线 softmax 与最终归一化串起来，验证端到端单行输出质量。

**原因**：

- 仅看 online update 不足以评估最终输出误差；
- 单行 reduction core 是主线 compute kernel 的较好代理；
- 该组能帮助判断 base-2 路线是否值得进入 `fa_attention_core`。

**实验变体**：

- `base`：使用 base-2 online softmax + 现有 reciprocal
- `exp_a`：切换到更高精度 fractional LUT online softmax

**评估项**：

- 行级最终输出误差
- 功能稳定性
- STA 与面积

### 实验组 D：`fa_row_norm_vec`

**目的**：评估归一化尾段的低风险周期优化空间。

**原因**：

- `ms_normalize_cycles` 虽然不是最大项，但优化成本低；
- 可直接服务 baseline 周期优化；
- 受面积约束影响相对可控。

**实验变体**：

- `base`：8-lane
- `exp_a`：16-lane
- `exp_b`：32-lane

**评估项**：

- 单行归一化输出一致性
- 面积/时序随 lane 扩大变化
- 周期缩减的理论收益

## 5. 本轮实验的判定标准

每组实验至少输出以下结论：

1. **功能是否通过 cocotb**
2. **STA 是否优于当前可比实现**
3. **误差是否处于可接受范围**
4. **面积是否明显恶化**
5. **若插入 baseline，可能改善的是 Fmax、cycles，还是两者都改善**

筛选原则：

- 若只提升局部 Fmax、但显著增加系统等待，不进入主线候选；
- 若精度明显劣化，不进入主线候选；
- 若面积增量与 2M 门预算不匹配，不进入主线候选；
- 优先保留“**面积小增量 + 可独立替换 + 对系统调度友好**”的方案。

## 6. 本轮实验后的预期决策

本轮不承诺立即合入主线，但会在实验完成后给出明确分类：

- **可直接作为主线候选**
- **需要与调度重构一起考虑**
- **仅保留为研究支线**

当前预期最可能进入下一步主线候选的是：

1. `fa_exp2_lut_q1_15`
2. `fa_online_softmax_base2`
3. `fa_row_norm_vec` 的中等并行版本

而真正涉及周期大幅下降的主线机会，仍更可能来自后续：

- 行级 overlap
- softmax / PV 更细粒度交叠
- compute 控制气泡压缩

## 7. 立即执行项

按以下顺序推进：

1. 建立并提交本说明文档；
2. 创建 4 组实验目录与 RTL/TB；
3. 完成 lint / cocotb 验证；
4. 完成模块级 STA；
5. 汇总结果，决定下一轮是否推广到主线。
