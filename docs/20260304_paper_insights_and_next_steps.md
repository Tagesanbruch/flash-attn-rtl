# 2026-03-04 论文对比分析与下一步优化方向

## 1. 当前实现瓶颈（基线）

基于现有 profiling：
- total_cycles = 1,365,248
- non_dma_cycles = 1,328,385（97.30%）
- DMA相关仅约 36,863（2.70%）

说明：当前主要矛盾不是带宽，而是内核计算/控制流水效率。

---

## 2. 论文方法与可迁移启示

### A) SpAtten (arXiv-2012.09852)
来源：`papers/arXiv-2012.09852v3`

**怎么做**
- 算法-硬件协同：cascade token pruning + cascade head pruning + progressive quantization。
- 用高并行 top-k 引擎在线选择保留 token/head（O(n) 平均复杂度）。
- 数据流上按 head、query 逐步处理，保留必要 K/V 复用并减少 DRAM 拉取。

**关键结果（论文中给出）**
- 平均 DRAM 降低 10.0×，计算降低 2.1×。
- 相对 A3 1.6× 吞吐、3.0× 相对 MNNFast。
- 相对 TitanXp/Xeon 等平台报告大幅 speedup 与能效优势。

**对当前架构启示**
- 强启示：在线“选择性计算”能显著降总体工作量。
- 但对本赛题 baseline 约束（固定 S=256,d=64 且正确性门限）需要谨慎：
  - token/head pruning 会改变计算语义，不适合作为 baseline 主路径。
  - 更适合作为 Bonus 版本（可配置近似/稀疏模式）。

---

### B) Approx Softmax (arXiv-2501.13379)
来源：`papers/arXiv-2501.13379v2/output.tex`

**怎么做**
- 评估 Taylor 与 LUT 插值近似 softmax 的误差-时延-资源权衡。
- 结论是低阶 Taylor 在资源/时延上更有利，LUT（二次插值）误差更低。

**关键结果（论文中给出）**
- 二次 LUT 插值 RMSE 最低（2.31e-7）。
- 三阶 Taylor RMSE 4.18e-5。
- 在其模型实验中，Taylor 可实现较低资源开销并保持较好精度（文中示例有 14% 资源节省）。

**对当前架构启示**
- 与你当前 exp-PWL 路径一致：softmax 非线性近似是可行工程路径。
- 下一步更值得做的是：
  - 分段/系数优化（非均匀分段、偏向负尾区间）
  - 与在线 softmax 误差联动评估，而不是单点 exp 误差最小化

---

### C) FlatAttention (arXiv-2505.18824)
来源：`papers/arXiv-2505.18824v1/paper.tex`

**怎么做**
- 在多 tile many-PE 架构上，把多个 tile 组成 group 共同处理一个更大块。
- 核心是“以片上 collective 通信换 HBM 访问”：
  - west/south edge tile 读取 Q/K/V；
  - group 内通过 row/column multicast；
  - 最后 row-wise reduction 汇总 O。
- 再叠加异步重叠：SoftMax / data movement / GEMM overlap。

**关键结果（论文中给出）**
- 相比 FA-3（同类 tile-based 配置）最高 4.1× 性能，16× HBM traffic 降低。
- 在其最优配置下，MHA 利用率最高 89.3%。
- 讨论了 over-flattening：group 过大时，短序列会因同步开销与切片过小导致利用率下降。

**对当前架构启示**
- 你当前是单 IP/单核风格，无法直接复用 NoC collective。
- 但其思想可迁移为“模块内局部 collective/复用”：
  - 一次加载后让 K/V 在更多计算阶段被复用；
  - 把 data movement 与 softmax/value 累加更深重叠，减少空泡。

---

### D) FSA / MSAGA (arXiv-2507.11331 + ref/FSA Chisel)
来源：`papers/arXiv-2507.11331v4` 与 `ref/FSA`

**怎么做**
- 把 FA 整体融合到单个 systolic array：
  - 行归约（rowmax/rowsum）在阵列内做；
  - exp2 用 PWL，复用 MAC 数据通路；
  - 不依赖外部 vector/scalar 单元。
- 关键在“操作级重叠调度”而不是串行阶段执行。

**数据流特征**
- 同一 inner-loop 内重叠：QK、rowmax、减法、exp2、rowsum、PV。
- 给出 tile 周期模型：
  - 约 5N+10（inner loop）
  - re-scale 约 2N+20（outer loop 收尾）

**关键结果（论文中给出）**
- 相对 Neuron-v2 / TPUv5e 的 attention FLOPs 利用率提升 1.77× / 4.83×。
- 16nm, 1.5GHz 综合；额外面积约 12.07%。

**对当前架构启示（最直接）**
- 你当前 compute 主路径仍偏“阶段化串行 + pair 粒度控制开销高”。
- FSA 的可落地点：
  1) 指令化执行计划（ExecutionPlan + conflictFree + semaphore）
  2) 双缓冲加载与 compute 交叠（见其 python kernel）
  3) 在一个 tile 内把 score/softmax/value 融合成连续流水

---

## 3. 对“是否继续优化乘法器/运算单元”的判断

结论：**要做，但优先级排在“数据流与调度重构”之后**。

- 乘法器、CSA、乘加树重构主要提升 Fmax/功耗/面积。
- 你当前最大的指标差距是 cycles（1.36M vs <300k），这更多由“每对(q,k)处理流程太串行”导致。
- 因此建议：
  1) 先做数据流/状态机重排，压低每对(q,k)的周期成本；
  2) 再做乘法树/CSA/打拍，保证时序与面积可收敛。

---

## 4. 当前总延迟的简算

定义：
- N_pair = S*S = 256*256 = 65,536
- 当前总周期约 = DMA + Compute
- 实测：DMA≈36,863；Compute≈1,328,385

用近似模型表示：

C_total ≈ C_dma + N_pair * (D/L + C_overhead)

其中：
- D=64
- L=当前 dot 并行 lane（现为 4）
- C_overhead = pair 粒度固定状态开销（score/softmax/next 等）

代入当前情况：
- D/L = 16
- 对应实测可反推 C_overhead 约 4 左右
- 即每 pair 约 20 cycles，乘上 65,536 得到约 1.31M，和实测吻合。

要进 <300k：
- 预算给 Compute 约 <= 300k - 36.9k ≈ 263k
- 即每 pair 预算 <= 263k / 65,536 ≈ 4.0 cycles

这说明仅靠 lane 从 4 提升到 8/16 不够，必须同时大幅降低 C_overhead（通过融合流水与重叠）。

---

## 5. 下一步优化路线（按优先级）

### P0（立即）：建立“结构变更-收益”判定框架
- 在现有 `timeline/summary` 基础上，增加每状态停留计数与转换计数导出。
- 将 `C_DP_RUN`、`C_SOFTMAX_PREP`、`C_NEXT_*` 的周期占比固定化，作为每轮优化验收门槛。

### P1（最高收益）：重构 inner-loop 数据流（参考 FSA）
- 目标：把当前“pair串行状态链”改为“score/softmax/value 连续流水”。
- 手段：
  - 提前传播 rowmax/rowsum 所需数据，减少 pair 级状态切换；
  - 允许 load(K/V) 与部分 compute 重叠（双缓冲）。

### P2（中高收益）：提升 dot 与 value 的并行度，并统一归约路径
- 把 4-lane 提升到可配置更高 lane，同时避免控制开销线性放大。
- 对加法归约树做层次化/平衡化，减少组合深度。

### P3（时序收敛）：乘法器与关键路径工程化
- 对乘法和长加法链做 CSA/树规约/打拍。
- 明确把“单周期组合大路径”切分为可综合的多级流水。

### P4（可选 Bonus 版本）
- 参考 SpAtten 引入可配置 token/head 稀疏与 progressive quantization，做独立 Bonus 分支。
- 不污染 baseline 结果，符合赛题 bonus 独立版本要求。

---

## 6. 推荐的短期冲刺目标（两轮迭代）

- 迭代1：仅做 inner-loop 流水重构（不改数值近似），目标 cycles 再降 35%~45%。
- 迭代2：叠加 lane 扩展 + 归约树重构，目标总 cycles 进入 500k~700k 区间。

若两轮后仍显著高于 300k，再考虑更激进的“类 systolic 子阵列化”改造。

---

## 7. 面向“compute 周期”的细化分析（含新参考源码）

本节专门回答：这些工作在 compute 周期层面到底怎么省、是否可迁移到当前工程。

### 7.1 你当前 RTL 的周期分解（精确到状态粒度）

基于 `rtl/core/fa_attention_core.sv` 当前状态机（`C_DP_INIT/C_DP_RUN/C_SCORE_DONE/C_SOFTMAX_PREP/C_NEXT_KJ/C_NEXT_QI`）：

对每个 `(qi, kj)` pair（共 `S*S=65536` 个），当前近似周期是：

- `C_DP_INIT`: 1
- `C_DP_RUN`: `D/L = 64/4 = 16`
- `C_SCORE_DONE`: 1
- `C_SOFTMAX_PREP`: 1
- `C_NEXT_KJ`: 1

合计约 `20 cycles/pair`，再叠加 `C_NEXT_QI/C_DONE/normalize` 的摊销项，与实测 `Compute+Normalize+Ctrl=1,328,385` 一致。

关键结论：
- 这不是“乘法器太慢”的主问题，而是 **pair 粒度控制状态过多 + 阶段串行**。

### 7.2 FSA / MSAGA：为什么是 5N+10（可迁移性最高）

源码与论文对应：
- `ref/FSA/src/main/scala/fsa/ExecutionPlan.scala`
- `ref/FSA/src/main/scala/fsa/MatrixEngineController.scala`
- `papers/arXiv-2507.11331v4/3-algorithm.tex`

核心不是“更快乘法器”，而是 **执行计划化 + 可重叠调度**：

1) inner-loop 指令拆分：`LoadStationary -> AttentionScore -> AttentionValue`
2) `MatrixEngineController` 内双 FSM 允许两条 compute 指令重叠（并受 `conflictFree` 约束）
3) `AttentionScoreExecPlan` 在一次 score 流中串接 rowmax、减法、exp2、rowsum 准备，减少阶段切换空泡
4) `AttentionValueExecPlan` 以最小间隔接续，形成“流水接力”

由此得到论文给出的 tile 模型：
- inner-loop: `5N + 10`
- re-scale: `2N + 20`

对你的借鉴意义：
- 可直接迁移“冲突可证明的重叠控制”思想，而不必一次性上完整 systolic array。

### 7.3 SpAtten（新 clone 源码）：compute 吞吐如何建模

关键源码：
- `ref/spatten/spatten_hardware/hardware/src/main/scala/spatten/SpAtten.scala`
- `ref/spatten/spatten_hardware/hardware/src/main/scala/spatten/DotProduct.scala`
- `ref/spatten/spatten_hardware/hardware/src/main/scala/spatten/MultiplyValue.scala`
- `ref/spatten/spatten_hardware/hardware/src/main/scala/spatten/SpAttenController.scala`
- `ref/spatten/spatten_hardware/hardware/src/main/scala/spatten/sim/TopKLatencyModel.scala`
- `ref/spatten/spatten_hardware/simulator/src/bert.cpp`

从代码看其“每周期并行度”是明确参数化的：
- `numMultipliers=512`, `sizeD=64` -> `numSoftMaxUnit=8`
- `DotProduct` 一拍可产出最多 8 个 score（BMR: broadcast-multiply-reduce）
- `MultiplyValue` 同样用 BMR 并跨拍累加

TopK 延迟模型（sim）不是常量：
- 近似 `sum(iter) ((seq_i + P - 1)/P + 3)`，`P=parallelism`

另外它在 `bert.cpp` 给了简化流水尾延迟估算：
- keymat: `1+1+9`
- softmax: `7+21+23+29+7+batch`
- valmat: `1+1+1`

对你的借鉴意义：
- “并行度参数化 + BMR 统一核 + 分支代价显式建模”非常值得学。
- 但其 token/head pruning 改变语义，baseline 不宜直接引入。

### 7.4 hls-fpga-accelerators：softmax 周期特征

关键源码：
- `ref/hls-fpga-accelerators/softmax/softmax.cpp`
- `ref/hls-fpga-accelerators/common/config.h`

可见其 softmax 是两次流式遍历：
1) pass1: 读入并累计 `sum(exp(x))`
2) pass2: 再读入并输出 `exp(x)/sum`

并行度来自 `kPackets = BUS / dataWidth`，每拍处理 `kPackets` 元素；
总周期近似：

`C_softmax ≈ 2*(N/kPackets) + (N/kPackets) = 3N/kPackets`（load 两遍 + store 一遍，忽略小常数）

对你的借鉴意义：
- 流式 + unroll + dataflow 能把吞吐打满；
- 但“两遍输入”在你的在线 softmax 场景不优，不宜照搬算法形态。

---

## 8. 面向当前工程的更细化 RTL 改造计划（含预估收益）

以下只针对 baseline 主线（不改变语义）。

### 阶段A：先砍控制开销（目标 -30%~-40% cycles）

改造点：
1) 合并 `C_SCORE_DONE + C_SOFTMAX_PREP + C_NEXT_KJ`，形成单拍或双拍“后处理”
2) 把 `C_NEXT_QI` 吸收到 pair 尾部控制，避免额外空拍
3) 将 `comp_done` 判定改为流式尾标志，减少 `C_DONE` 往返

预期：
- `C_overhead` 从约 4 降到约 2~2.5（每 pair）
- 总周期可先降到约 900k~1,000k。

### 阶段B：重排 inner-loop 为两级流水（目标再降 25%~35%）

改造点：
1) 建立 `DotPipe`（仅点积）与 `SoftmaxAccPipe`（m/l/acc 更新）
2) `DotPipe` 产出 `(qi,kj,score)` FIFO；`SoftmaxAccPipe` 消费
3) 引入 score FIFO 深度（建议 4~8）做弹性解耦

这一步本质上是把 FSA 的“指令级重叠”映射为你当前单核的“模块级重叠”。

预期：
- `D/L` 与后处理重叠一部分，pair 有效成本继续下降
- 总周期进入约 600k~750k 区间。

### 阶段C：并行度与归约树协同（目标再降 20%~30%）

改造点：
1) lane 从 4 提升到 8（先 8，避免一次到 16 带来时序爆炸）
2) dot 与 pv 路径采用平衡加法树，必要时加 1 级 pipeline
3) 对 `row_acc` 更新链做局部 CSA 化，降低组合深度

预期：
- `D/L` 从 16 到 8
- 如果与阶段A/B叠加，目标可逼近 `400k~550k`。

### 阶段D：冲击 <300k 的结构级动作（高风险）

当 A/B/C 后仍 >300k，再做：
1) 双对并行（同拍处理两个 `kj` 或两个 `qi`）
2) K/V tile 内更深双缓冲，load 与 compute 完全交叠
3) “小型阵列化”子模块（不是完整 systolic 重写）

---

## 9. 建议的实施顺序与验收口径

### 每轮必须输出
1) Verilator C++ 精度门限
2) cocotb 核心 + top 寄存器（含 CYCLES）
3) latency breakdown（before/after）

### 每轮核心指标
- pair 有效周期（从事件统计反推）
- `Compute+Normalize+Ctrl` 占比
- DMA 是否开始上升（防止“算快了但喂不饱”）

### 推荐三轮冲刺目标
- R1: 1.36M -> <=1.0M
- R2: <=1.0M -> <=700k
- R3: <=700k -> <=450k（若要 <300k，进入阶段D）

注：按照当前约束与架构，不引入更激进并行形态时，直接到 <300k 的概率较低。

---

## 10. cmodel 计算阶段（compute-only）周期仿真验证

已新增 cmodel 选项：
- `--run-compute-cycle-model`
- `--cycle-csv-out <path>`

对应产物：
- `docs/data/20260304_compute_cycle_models_s256d64.csv`

命令：

```bash
cd cmodel
make run-compute-cycles
```

### 10.1 仿真假设（仅 computing）

- 不计 DMA（符合本轮讨论焦点）
- 不建模乘法器频率/时序（只看周期结构）
- 只建模 pair 处理流水与归一化周期

### 10.2 结果（S=256, D=64）

- `rtl_current_serial_l4`: `1327104`（FAIL）
- `merge_post_serial_l4`: `1261568`（FAIL）
- `dp_post_overlap_l4`: `1131008`（FAIL）
- `dp_post_overlap_l8`: `606720`（FAIL）
- `dp_post_overlap_l16`: `344576`（FAIL）
- `dp_post_overlap_l16_norm4`: `332288`（FAIL）
- `dp_post_overlap_l16_norm4_row2`: `168192`（PASS）

### 10.3 结论（直接回答“300k 怎么流”）

仅做以下任一项都不够：
- 只合并后处理状态
- 只做 DP/POST 重叠
- 只把 lane 提升到 8 或 16

要达到 `<300k`（在 compute-only 维度），至少需要组合：
1) `DP/POST` 两级重叠流水；
2) `dot lane` 提升（接近 16 级别）；
3) 归一化向量化（例如 norm 每拍 >=4 元素）；
4) 行级并行（至少 2 行并行处理）或等效并发策略。

这与 FSA/MSAGA 的核心启示一致：**关键是数据流重叠与并发粒度，而不是单点算子优化。**
