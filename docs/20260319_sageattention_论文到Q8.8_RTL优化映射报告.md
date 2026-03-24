# 2026-03-19 SageAttention（2410.02367）到 Q8.8 RTL SDPA 的优化映射报告

## 0. 结论先行

- **可以借鉴，且值得借鉴**：SageAttention 的核心价值不是“必须用 FP8/FP16”，而是一套“**先控制分布，再做低比特计算，再用低开销补偿误差**”的方法论。
- 对你当前路线（Baseline 约束下的 Q8.8 RTL online-softmax）最可迁移的三点：
  1) **K 平滑（去 token 维均值）**；
  2) **分层/分块动态缩放 + 统计驱动调参**；
  3) **两级累加（短程高吞吐 + 长程高精度回灌）**。
- **重要澄清**：2410 这篇论文正文主推的是 `INT8(QK) + FP16(PV, FP16 Acc)`；你提到的 `FP8(PV)` 主要体现在 SageAttention 后续代码/版本（仓库中已实现），不是 2410 正文主结论。
- 即使路线不一致（你是 RTL 定点，SageAttn 是 GPU kernel），其误差控制思想仍可直接映射到你们的 cmodel/RTL 收敛闭环，并有望降低当前 mode15 的生成失真。

---

## 1. SageAttention（2410）到底做了什么

## 1.1 算子分解与低比特化对象

论文把 attention 拆成两段：

1. `QK^T`（score 计算）
2. `P*V`（权重加权求和）

并采用 online-softmax 框架（不显式存 `SxS` 矩阵），在这个基础上做量化。

关键策略：

- `Q,K`：INT8 动态量化（per-token / per-block / per-tensor 可选）
- softmax 在线递推（`m/l/acc`）：保留高精度计算（论文中是浮点）
- `P,V`：论文最终主推 FP16 路径（不是全 INT8），以避免某些层灾难性误差

> 核心思想：把“最敏感”的非线性与累加环节从极低比特中解耦，让低比特主要承接 matmul 吞吐。

## 1.2 误差优化关键：Smooth K

论文最关键可迁移点是对 `K` 做去均值：

$$
K' = K - \mathrm{mean}_{token}(K)
$$

并说明这不会改变 softmax 结果：

$$
\sigma(q(K-\bar K)^T) = \sigma(qK^T - q\cdot \bar K) = \sigma(qK^T)
$$

这一步的作用不是“改算法”，而是：

- 去掉 K 中跨 token 共享的大偏置；
- 显著收敛量化动态范围；
- 减少 QK 量化误差外溢到后续 softmax 的风险。

论文与附录里都显示：**不做 Smooth K 时误差和端到端退化会明显放大**。

## 1.3 为什么 QK 选 INT8，PV 不盲目 INT8

论文实验结论：

- `QK` 用 INT8 比 FP8（E4M3/E5M2）更稳（至少在其测试模型分布里）。
- `PV` 若也压到 8-bit，平均指标可能还行，但**最坏层**会出现不可接受误差。
- 因此 2410 主线选择 `PV -> FP16 + FP16 accumulator`，在准确率和性能间折中。

这和你当前现象非常一致：

- 随机张量误差可接受，不代表端到端生成质量可接受；
- 真正问题常发生在少量高敏层/位置，并被层间累计放大。

## 1.4 自适应策略（Adaptive Quantization）

论文不是“一刀切用一个核”，而是：

- 准备精度/速度不同的核（更稳 vs 更快）；
- 按层统计指标（如 cosine）选择可接受的更快核；
- 其余层回退到更稳核。

这本质上与你当前 `mode14`（稳）/`mode15`（目标定点）并行策略高度同构。

---

## 2. 你关心的 FP8(PV)+INT8(QK) 是如何控误差的（结合仓库实现）

## 2.1 先说明来源差异

- 2410 正文主线：`INT8(QK) + FP16(PV)`。
- 你问的 `FP8(PV)`：在 `ref/SageAttention` 的后续实现中有完整 kernel（sm89/sm90 路径）。

## 2.2 FP8(PV) 的实操控误差手段

从仓库实现可见（`sageattention/core.py`, `sageattention/quant.py`）：

1. **V 按通道量化（per-channel FP8）**
   - 与 QK 的 per-block/per-thread 不同，V 用 per-channel scale，针对通道 outlier。

2. **V 预处理重排 + pad + 量化融合**
   - 先 transpose/pad/permutation，再量化，匹配底层 kernel 访存与张量核组织。

3. **可选 smooth_v（V 去均值）**
   - 在“低精度累加”场景可提升稳定性。

4. **scale 上限策略（scale_max）**
   - 默认 E4M3 上限 `448`；某些累加模式下改更保守阈值（代码里出现 `2.25`）以换稳定性。

5. **两级累加（inst_buf）**
   - 注释中明确：硬件 FP32 累加器有效位有限（提到“FP22”现象）；
   - 做法：短程累加在快速路径，**周期性写入长期 buffer（更稳）**。
   - 这和“长期状态防漂移”的工程思想对 RTL 定点非常有借鉴价值。

## 2.3 对你的启发

你们虽然不是 FP8 MMA，但可以复刻同一思想：

- 不执着“每一步都同一种精度”；
- 允许短程/长程使用不同位宽或归一化节奏；
- 用固定成本的“周期回灌”抑制累计漂移。

---

## 3. 对当前 Q8.8 RTL 架构的可迁移设计（可直接执行）

下述设计均以不偏离 Baseline（Q8.8 输入输出、online-softmax、可综合）为前提。

## 3.1 迁移点A：K 平滑（强推荐，P0）

### 目标
降低 score 动态范围和尾部 outlier 放大。

### 方案
在每个 head、每层、每个 decode step（或 tile）上对 K 做：

$$
K' = K - \bar K,
\quad \bar K = \frac{1}{T}\sum_{t=0}^{T-1}K_t
$$

### 两种落地

1. **离线/块内均值（先做）**：tile 内求均值，低成本验证收益；
2. **在线均值（最终）**：随着 `seq_len` 增长维护 running mean。

### 风险与规避

- 风险：均值路径增加硬件开销与时延。
- 规避：先在 cmodel + native 后端验证收益，再决定 RTL 常驻或可配。

## 3.2 迁移点B：两级累加（短程+长程，P0/P1）

### 目标
解决“随机误差小但端到端崩”的累计漂移。

### 方案（定点版 inst_buf 思路）

- `acc_short`：较小位宽/高吞吐，按 token 或小块快速更新；
- `acc_long`：更高位宽（如 48/56b）长期缓冲；
- 每 `K` 步执行：`acc_long += renorm(acc_short)`，并重置/缩放 `acc_short`。

对 `l` 也做相同“短长双状态”维护，避免分母漂移造成归一化失真。

### 关键点

- 回灌周期 `K` 可配置（8/16/32）；
- 回灌时统一 rounding 策略（向零/最近偶数等）并全链路一致。

## 3.3 迁移点C：分块动态缩放与饱和监控（P0）

### 目标
将误差从“不可见累计”变成“可观测、可调参”。

### 方案

在 `score/exp/l/acc/norm` 各阶段增加统计计数器：

- 饱和计数；
- 最大绝对值（amax）；
- 缩放触发次数；
- 关键差分（对 mode14 参考）。

并导出到 perf/diff log，形成自动阈值调参闭环。

## 3.4 迁移点D：自适应层策略（P1）

### 目标
先恢复可读性，再逐步扩大纯定点覆盖。

### 方案

- 以 `mode14` 作为稳定参考，`mode15` 作为目标实现；
- 先按层/头/pos 打分（如 max_abs_lsb、top-k overlap、最终 token 质量）；
- 对高风险层暂时回退稳态策略，低风险层保留纯定点；
- 用回归结果持续缩小回退范围。

这与 SageAttention 的 adaptive kernel 选择思路一一对应。

---

## 4. 面向你当前代码栈的具体改造建议

## 4.1 cmodel 层（优先）

建议首先扩展 `cmodel/csrc/attention_kernels.cpp`：

1. `mode15` 增加 `k_smooth` 开关；
2. 增加 `l/acc` 双状态（short/long）选项；
3. 增加分阶段统计导出（每层每头每 pos）：
   - `score_amax`, `exp_amax`, `l_short/long`, `acc_short/long`, `norm_den`。

## 4.2 native bridge / inference

在 `inference/native/flash_attn.c` 扩展环境开关：

- `FLASH_ATTN_CMODEL_K_SMOOTH`
- `FLASH_ATTN_CMODEL_ACC_DUALBUF`
- `FLASH_ATTN_CMODEL_ACC_FLUSH_EVERY`
- `FLASH_ATTN_CMODEL_STAGE_TRACE`

并复用你现有 `REAL_DIFF/HOTFIX` 管线，保持 A/B 可复现。

## 4.3 RTL 目标模块

重点映射到：

- `rtl/core/fa_online_softmax_ctx.sv`
- `rtl/core/fa_attention_core.sv`
- `rtl/core/fa_o_normalize_block.sv`

优先次序：

1. rounding 一致化；
2. l/acc 位宽与回灌策略；
3. K 平滑（可先做 tile-mean 版本）。

---

## 5. 实验设计：从“随机误差”升级到“生成质量闭环”

## 5.1 四层实验漏斗

### Stage A：算子级（随机张量）

- 指标：`mae_lsb`, `max_abs_lsb`, `diff_ratio`。
- 目的：快速排雷与参数初筛。

### Stage B：真实张量重放（你当前已在做）

- 数据：真实推理流中 layer/pos/head 张量；
- 指标：`max_abs` 热点分布、阶段内部状态偏移。

### Stage C：对 logits 的因果影响

- 指标：首发散点之后 `top-k overlap`, `logit KL`, `argmax flip rate`；
- 目的：找出“从数值偏差到文本坍缩”的放大节点。

### Stage D：端到端可读性

- 指标：固定 prompt 回归、重复 token 比例、困惑度/采样稳定度。

## 5.2 建议门槛（可先作为内部阈值）

- 算子级：`max_abs_lsb <= 1` 覆盖 > 99%；
- logits：`top-5 overlap` 在关键层/步维持高一致；
- 端到端：不出现稳定重复坍缩（如 `/API` 模式）。

---

## 6. 建议的三周执行路线（最小可行）

## Week 1：P0 快速验证

- 在 mode15 引入 `K-smooth`（先离线/tile）；
- 引入 `acc/l dual-buffer`（仅 cmodel）；
- 加阶段 trace 与自动统计脚本。

**产出**：是否显著降低真实张量热点与坍缩概率。

## Week 2：P1 策略收敛

- 扫描 `flush_every`、位宽、rounding；
- 建 layer-wise 自适应回退表（临时工程策略）。

**产出**：在可读性恢复前提下，最大化纯定点覆盖率。

## Week 3：RTL 映射

- 把 cmodel 已验证有效的 1~2 个机制移植 RTL；
- 做 cmodel-vs-rtl 对齐与端到端复测。

**产出**：可提交的“误差可解释 + 性能可量化”版本。

---

## 7. 风险清单与边界

- **不要直接照搬 FP8/FP16 数据类型**：你当前比赛 Baseline 目标是定点可综合；应迁移“方法”，不是照搬 dtype。
- **不要只看随机张量指标**：必须以真实推理分布和最终文本质量闭环验收。
- **不要一次性全局替换**：先 cmodel 开关化 A/B，再 RTL 最小改动迁移。

---

## 8. 回答你的三个核心问题

1. **是否有参考学习价值？**
   - 有，而且很高。最值得学的是“分布治理（Smooth）+ 低比特计算 + 累计误差补偿 + 自适应层策略”。

2. **FP8(PV)+INT8(QK)怎么控误差？**
   - QK 侧：K 去均值 + 合理粒度量化；
   - PV 侧：per-channel 量化、可选 V 平滑、两级累加（inst_buf）抑制短程低精度漂移；
   - 系统侧：按层选择更稳核，避免局部最坏层拖垮全局。

3. **我们能否效仿并正确接入 IP 核进入推理框架？**
   - 可以。建议按“cmodel 开关化验证 -> 实时张量差分 -> 端到端回归 -> RTL 最小迁移”推进。
   - 以你当前状态，最先做 `K-smooth + dual-buffer accum` 的 cmodel 验证，成功概率最高，且最符合你现有诊断框架。

---

## 9. 附：与你当前现状的直接对应

- 你现在的 `mode14` 可作为稳定参考、`mode15` 作为收敛目标，这与 SageAttention 的 adaptive 机制同构。
- 你已具备 real-diff/hotfix/role-prompt 回归流水线，正好可直接承接本文建议的实验漏斗。
- 当前“热点层局部替换无效”说明问题更偏全链路累计误差，而非单层点状 bug；这正是两级累加与分布治理应优先介入的信号。
