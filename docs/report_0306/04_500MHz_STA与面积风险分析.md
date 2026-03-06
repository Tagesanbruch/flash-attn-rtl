# 04 500MHz STA 与面积风险分析

## 4.1 本轮 STA 复核范围

本轮按当前 `cfg/sta_modules.mk` 支持列表，对以下模块进行了主线 RTL 的 500MHz 复核：

- `fa_clip_signed`
- `fa_mul_sat_q8_8`
- `fa_exp_pwl_8seg_q1_15`
- `fa_recip_nr_q16_16`
- `fa_online_softmax_update`
- `fa_row_reduction_core`
- `fa_axi_lite_regs`
- `fa_core_controller`

按用户上轮要求，本轮**不把 top 级 STA 伪装成已完成**。因此 `fa_attention_ip_top` 不给出正式达标结论。

## 4.2 模块级 500MHz 复核结果

| 模块 | Area | WNS @500MHz | TNS | 近似 Fmax | 结论 |
|---|---:|---:|---:|---:|---|
| `fa_clip_signed` | 58.52 | +1.346 ns | 0.000 | 1529.955 MHz | ✅ 通过 |
| `fa_mul_sat_q8_8` | 4469.36 | -0.313 ns | -9.447 | 432.317 MHz | ❌ 未过 |
| `fa_exp_pwl_8seg_q1_15` | 1892.52 | -0.507 ns | -8.320 | 398.917 MHz | ❌ 未过 |
| `fa_recip_nr_q16_16` | 59025.96 | +0.004 ns | 0.000 | 501.014 MHz | ✅ 临界通过 |
| `fa_online_softmax_update` | 22217.72 | -3.276 ns | -354.701 | 189.545 MHz | ❌ 主瓶颈 |
| `fa_row_reduction_core` | 89867.40 | -3.294 ns | -932.937 | 188.901 MHz | ❌ 主瓶颈 |
| `fa_axi_lite_regs` | 4399.64 | +0.729 ns | 0.000 | 787.069 MHz | ✅ 通过 |
| `fa_core_controller` | 531.16 | +1.277 ns | 0.000 | 1383.080 MHz | ✅ 通过 |

## 4.3 结果解读：哪些问题是“点状问题”，哪些是“架构问题”

### 4.3.1 点状问题

以下两个模块虽然没过 500MHz，但违例量级明显更小：

1. `fa_mul_sat_q8_8`
   - WNS `-0.313ns`
   - 量级接近 500MHz 边界

2. `fa_exp_pwl_8seg_q1_15`
   - WNS `-0.507ns`
   - 也属于局部组合路径偏长

这类问题通常对应：

- 增加 1 级流水；
- 拆分舍入/饱和；
- 改写 PWL 插值结构；
- 或重新选择更适合综合器的表达方式。

也就是说，它们是**可通过微结构修补继续优化**的。

### 4.3.2 架构级问题

真正严重的是：

- `fa_online_softmax_update`
- `fa_row_reduction_core`

二者约束下的可用频率都在 **189MHz** 左右，说明问题不是“差一点”，而是“差一个结构级方案”。

尤其 `fa_online_softmax_update` 中：

- `m_new` 形成；
- `diff_old / diff_new` 形成；
- PWL exp；
- `l_old * exp_old`；
- `acc_old * exp_old`；
- `exp_new * value`；
- 结果再加回 `l/acc`

这些运算在强依赖关系下形成长反馈回路，是当前冲频的决定性障碍。

## 4.4 为什么 `fa_recip_nr_q16_16` 已不再是当前主矛盾

本轮复核中，`fa_recip_nr_q16_16` 的 WNS 为 **+0.004ns**，对应约 **501MHz**。

这说明：

1. reciprocal 的 10 级流水改造在主线 RTL 中已经生效；
2. 它虽然只是在边缘闭合，但已经不应继续被描述为“当前 500MHz 下最大的未解问题”；
3. 后续若继续优化 reciprocal，更像是**增强 margin**，而不是决定系统成败的第一优先级。

## 4.5 为什么 `fa_row_reduction_core` 没有随着 reciprocal 一起闭合

`fa_row_reduction_core` 虽然集成了新的 reciprocal，并通过 `acc_delay[0:9]` 完成了 10 级结果对齐，但其 WNS 依然约为 **-3.294ns**。

这说明：

- reciprocal 尾段确实被修复了；
- 但 row reduction 的 setup 主路径仍然来自其前半段，也就是 online softmax 更新链；
- 因此 row reduction 的频率上限仍被锁定在约 189MHz，而不是由 reciprocal 决定。

## 4.6 top 级 500MHz 为什么本轮仍不能下结论

本轮没有完成 top 级正式 STA，因此不能说：

- top 已满足 500MHz；
- 或 top 必然不满足 500MHz。

但可以给出保守估计：

1. 当前计算面已经存在多个未过 500MHz 的核心算子；
2. 其中最重的 recurrence 型路径只有约 189MHz；
3. 因而在未进行新的结构性改造之前，**top 级 500MHz 大概率不能自然成立**。

也就是说，top 级当前最合理口径应为：

- **未正式闭合**；
- **从模块迹象看大概率也尚未闭合**；
- **必须在下一阶段结合新结构方案和 top 级 STA/物理实现再判断。**

## 4.7 面积：当前可确认的是什么

### 4.7.1 模块级面积没有失控

当前模块级 `synth_stat.txt` 显示：

- `fa_mul_sat_q8_8`：4469.36
- `fa_exp_pwl_8seg_q1_15`：1892.52
- `fa_recip_nr_q16_16`：59025.96
- `fa_online_softmax_update`：22217.72
- `fa_row_reduction_core`：89867.40

这些数值本身说明：

- 当前主线在关键模块层面没有出现“某一个局部模块面积暴涨不可控”的现象；
- reciprocal 的 10 级流水主要换来时序提升，面积增加是可理解且局部可接受的。

### 4.7.2 top 级面积仍是高风险项

但题目要求不是“局部模块面积好看”，而是：

$$
\text{Equivalent Gates} \le 2{,}000{,}000
$$

且**包含存储折算**。

当前 top 风险主要来自：

1. `fa_attention_core` 中较大的 tile buffer 与上下文存储；
2. 若这些存储以寄存器阵列综合，则面积会快速放大；
3. 当前还没有 top 级 Genus 口径的正式面积报告去证明其满足 2M 门。

因此，本轮面积结论只能是：

- **模块级面积可控**；
- **top 级 2M 门约束当前尚未被证明满足，且存在明显超标风险。**

## 4.8 本轮没有继续做 RTL 大改的 STA 视角解释

从 STA 角度，本轮没有继续改主线 RTL 是合理的，原因是：

1. 若只修 `fa_mul_sat_q8_8` / `fa_exp_pwl_8seg_q1_15`，仍无法解决 189MHz 级主瓶颈；
2. 若直接改 `fa_online_softmax_update`，则已经进入：
   - 反馈递推拆级；
   - 多上下文交错；
   - 流水对齐重排；
   - 甚至算法重写；
   这类**高风险结构改造**；
3. 在本轮目标是“完成正式报告”的前提下，更合适的做法是先把现状与调研任务拆清，而不是无依据地大改主线。

## 4.9 本章结论

本章最终结论：

- 当前主线 RTL 的模块级 500MHz **并未全面达标**；
- 真正的第一瓶颈是 `fa_online_softmax_update` 及其在 `fa_row_reduction_core` 中体现出的同类反馈链；
- `fa_recip_nr_q16_16` 已从“主要未解问题”转变为“边界通过模块”；
- top 级 500MHz 与 2M 门面积约束都仍需后续正式闭环；
- 下一阶段最需要的不是继续微调，而是寻找**可验证的新微架构方案**。