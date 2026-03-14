# 2026-03-15 BF16/FP16 与 INT8/FP8 路线理论分析（周期、算力、带宽、架构）

## 1. 目的与范围

本文回答两个问题：

1. 为什么当前 BF16 仍在 2M cycles 量级，是否主要由“单 FMA 太慢”导致，是否值得围绕单 FMA 延迟继续优化；
2. INT8/FP8 是否需要引入类似 Tensor Core 的 MMA 架构，以及如何与当前分支的 BF16/FP16 工作衔接。

并统一给出：

- 周期理论模型；
- 算力口径（x GOPS/GHz、x attns/s/GHz）；
- 带宽与 DMA 利用率；
- 主要计算组件利用率；
- BF16/FP16 复用策略（不重新生成另一套 RTL 的可行性）。

## 2. 数据与基线

### 2.1 参数与问题规模

默认参数：`S=256, D=64`。

- pair 数：

$$
N_{pair}=S\times S=65,536
$$

- 注意力核心等效 MAC 数（QK + PV）：

$$
N_{MAC}=2\times S\times S\times D = 8,388,608
$$

- 等效 OPS（按 1 MAC = 2 OPS）：

$$
N_{OPS}=16,777,216
$$

### 2.2 采用的实测周期

- BF16 fix1：`8,573,025` cycles
- BF16 pipev1（当前最优）：`2,150,497` cycles
- Q8.8 主线：`85,928` cycles

### 2.3 外存流量（单次 attention）

按 `BUS_W=128bit=16B/beat`，Q/K/V/O 均 16-bit 元素：

- Q 读：32 KB
- K 读：256 KB
- V 读：256 KB
- O 写：32 KB

总流量：

$$
B_{total}=576\text{ KB}=589,824\text{ B}
$$

总 beat：

$$
N_{beat}=589,824/16=36,864
$$

## 3. 问题（1）：BF16 为什么仍是 2M 量级

## 3.1 先给结论

当前 BF16 的主瓶颈不是 DMA，也不是“单个 FMA 延迟太长”，而是：

1. 每个 pair 仍要在 D 维上做多拍推进；
2. online softmax 的 loop-carried dependency 限制了跨 pair 的理想流水；
3. 调度重叠深度与 Q8.8 主线相比仍不足。

也即，当前是“吞吐/并行度/重叠度问题”，不是“某个 leaf FMA 多了几拍就决定全局 2M”的问题。

## 3.2 pair 级模型与实测吻合

从 BF16 历史与当前版本可统一成：

$$
C_{total}\approx N_{pair}\cdot C_{pair}+C_{other}
$$

其中 `C_other` 主要是 load/norm/write 固定项。

- fix1：
  - `C_pair=130`（64 dot + 64 softmax + 2 控制）
- pipev1：
  - `compute=2,097,152`，故

$$
C_{pair}=2,097,152/65,536=32
$$

这已经说明：从 8.57M 到 2.15M 的大幅下降，核心是 pair 吞吐改进（lane + overlap），而非 DMA 变化。

## 3.3 是否由“单 FMA 过慢”主导

若单 FMA 延迟是主因，应看到“leaf pipeline 改动导致成比例总周期变化”。

但当前观测是：

- 周期主要随 `P_dot/P_sm` 与控制重叠变化；
- 非 compute 固定项始终很小（约 53k）；
- 说明系统受限于 `II` 与依赖链，而不是单算子 latency 本身。

只要单算子还能维持 `II=1`，其额外 pipeline 深度通常主要影响 fill/drain，而不会把 2.15M 直接变成同量级倍增。

因此：

- 继续优化 leaf FMA 有价值（时序/功耗）；
- 但若目标是再砍大周期，优先级应低于“跨 pair 流水重叠”和“调度重排”。

## 3.4 统一算力口径（理论 + 实测）

定义：

$$
\text{attns/s/GHz}=\frac{10^9}{\text{cycles}}
$$

$$
\text{GOPS/GHz}=\frac{N_{OPS}}{\text{cycles}}
$$

$$
\text{GMAC/GHz}=\frac{N_{MAC}}{\text{cycles}}
$$

计算结果：

| 路径 | cycles | attns/s/GHz | GOPS/GHz | GMAC/GHz |
|---|---:|---:|---:|---:|
| BF16 fix1 | 8,573,025 | 116.65 | 1.957 | 0.979 |
| BF16 pipev1 | 2,150,497 | 464.99 | 7.803 | 3.901 |
| Q8.8 主线 | 85,928 | 11,637.98 | 195.247 | 97.624 |

结论：BF16 到目前为止的吞吐仍远低于 Q8.8，主要不是位宽本身，而是调度形态不同。

## 3.5 带宽与 DMA 利用率

平均带宽（全程）：

$$
BW_{avg}=\frac{589,824}{\text{cycles}}\text{ B/cycle}
$$

折算 GB/s/GHz：

$$
\text{GB/s/GHz}=\frac{589,824}{\text{cycles}}
$$

| 路径 | B/cycle | GB/s/GHz | 相对 16 B/cycle 总线利用率 |
|---|---:|---:|---:|
| BF16 pipev1 | 0.2743 | 0.2743 | 1.71% |
| Q8.8 主线 | 6.8642 | 6.8642 | 42.90% |

额外看 BF16 pipev1 的 DMA 活跃态：

- 活跃态周期约 `load_q+load_k+load_v+write_o=36,944`
- 需要传输 beat 数 `36,864`

$$
\eta_{dma,active}=36,864/36,944\approx 99.78\%
$$

说明：DMA 子系统在自己活跃窗口里并不慢，系统整体仍是 compute-bound。

## 3.6 主要计算组件利用率（BF16 pipev1）

基于 `fa_attention_core_bf16fp32` 的实例数量（14 mul, 8 add, 12 bfloat widen, 2 downcast, 1 softmax scalar）与状态计数，可得到近似利用率：

1. dot 乘法阵列（4x mul）忙时约 `dp_run=1,048,576` 周期：

$$
U_{dot}\approx 1,048,576/2,150,497=48.76\%
$$

2. acc/v 更新乘法阵列（8x mul）在 `S_ACC_UPDATE` + 融合首拍也接近同量级忙时：约 48%~49%。

3. score 缩放/掩码/softmax 标量链（单路）每 pair 1 次：

$$
U_{score}\approx 65,536/2,150,497=3.05\%
$$

4. normalize 乘法（单路）约 16,384 周期：

$$
U_{norm}\approx 0.76\%
$$

结论：最重的是向量路径（dot + acc），不是标量 softmax 控制链。

## 3.7 BF16 与 FP16 是否要做成两套 RTL

目标是“不重新生另一组参数化 RTL”，结论是可行，建议统一做一套 16-bit 浮点前端：

1. 存储与 DMA 路径完全复用（都为 16-bit）；
2. 内部统一到 FP32 累加；
3. 增加 `precision_mode`（BF16/FP16）控制 widen/downcast 解释与舍入策略；
4. score/acc/norm 主框架保持不变。

优点：

- 不需要复制控制器与总线逻辑；
- BF16/FP16 可共享验证框架与 perf counters；
- 便于后续混合精度实验。

风险：

- 转换单元与舍入逻辑路径可能拉长关键路径；
- 如果对频率极敏感，可保留综合开关：`RUNTIME_MODE`（单网表）与 `BUILD_MODE`（双网表）并行支持。

## 3.8 工业上“FP16/BF16 约等于 2x INT8”如何理解

这是在相近架构、同等数据复用、同类 MMA 阵列条件下的峰值吞吐经验值，不是普适常数。

当前项目中 BF16 与 Q8.8 的差距远大于 2x，主要因为：

1. 两条路径的调度重叠深度不同；
2. 递推依赖处理方式不同；
3. 向量单元利用率不同；
4. 不是同一套“统一 MMA 引擎 + 统一编程范式”下的 A/B。

## 4. 问题（2）：INT8/FP8 与 Tensor Core/MMA 路线

## 4.1 是否需要“4 个低精度 Tensor Core + MMA 接口”

不建议一步到位复制 GPU 形态，但建议引入“类 MMA 微操作接口”，再逐步替换内部执行体。

推荐分两层：

1. 调度层：定义稳定的 tile 级操作（例如 `MMA(m,n,k, dtype, acc_dtype)`）；
2. 执行层：先由现有 vector MAC 实现，再演进为 systolic/tensor array。

这样可以先稳定软件/验证接口，再逐步升级硬件，不会一次性承担全部架构风险。

## 4.2 INT8/FP8 的执行体建议

### INT8

- 首选 `INT8 x INT8 -> INT32` 的向量/阵列 MAC；
- 累加维持 INT32，输出再量化；
- 重点做 scale 管理与饱和策略，而不是先追极限阵列规模。

### FP8

- 乘加主路径仍建议采用真正的低精度浮点乘加（或 block-floating 近似），不建议用 LUT 直接做通用 MAC；
- LUT 更适合用于 exp/recip 近似、转换与激活类函数；
- FP4 可考虑更多 LUT 化，FP8 一般仍需要算术数据通路。

## 4.3 是否引入脉动阵列

当前最重路径本质是向量点积与向量累加。若后续目标是 INT8/FP8 高吞吐、低 pJ/op，脉动阵列是有必要评估的中期方向；但短期更建议：

1. 先把现有 vector 引擎抽象成 MMA 微操作；
2. 做 1 个小规模阵列原型（如 8x8 或 16x8）验证吞吐/面积/时序；
3. 再决定是否扩到“每簇 4 阵列”这一级。

## 4.4 与 BF16/FP16 当前分支的衔接

建议路线：

1. 先完成 BF16/FP16 统一 16-bit 浮点前端与分支收尾；
2. 同时在独立分支定义 MMA 微接口和最小可运行 INT8 kernel；
3. 再引入 FP8（先转换/量化链，再 MAC）；
4. 最后评估阵列化与多核复制（是否需要 4 个低精度阵列）。

## 5. 直接回答两个问题

1. BF16 当前 2M 量级不是单 FMA 周期太长主导，而是 pair 级串行推进与递推依赖下的重叠不足主导；优化优先级应放在跨 pair 流水和调度重排。
2. INT8/FP8 值得朝 MMA 方向演进，但不建议一次性仿 GPU 形态。应先固定调度接口，再逐步替换执行体；FP8 的 LUT 适合函数近似，不适合通用 MAC 主路径。

## 6. 建议的下一步（面向当前 branch）

1. BF16/FP16：实现单 RTL 双模式 `precision_mode`（BF16/FP16），保持 FP32 accumulation；
2. BF16：继续做跨 pair 流水重叠，目标把 `C_pair` 从 32 再向 24~16 推进；
3. 指标体系：补充统一 perf 统计（attns/s/GHz, GOPS/GHz, GB/s/GHz, 模块 busy ratio）；
4. INT8/FP8：先做 MMA 微接口草案与 INT8 最小内核，不直接上多阵列复制。

## 7. 备注

本文的 Tensor Core/MMA 讨论采用公开架构常识与本项目数据推导，不直接复述外部文章原文。外部观点仅作为方向性参考。