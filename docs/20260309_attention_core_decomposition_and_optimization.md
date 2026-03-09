# `fa_attention_core` 拆分落地与后续优化分析

## 1. 本次 RTL 拆分落地内容

本次没有直接把 `fa_attention_core` 一次性拆成多个独立大状态机，而是先做**行为等价、接口清晰、风险可控**的第一阶段拆分：保留原有 tile 级调度/FSM，不改 DMA 与 top 接口，只把核心 datapath 中最重、最适合后续流水化的 3 段子路径抽出为独立子模块。

### 1.1 已新增的 3 个子模块

1. **`fa_qk_dotprod_slice`**  
   - 职责：对当前 `(q_pair, k_j, d_chunk)` 计算一拍的 QK 点积部分和。  
   - 接口特点：
     - 参数化 `D`、`DP_LANES`
     - 输入为两行 Q、一行 K、当前 chunk index
     - 输出两行 partial sum
   - 作用：把原来内嵌在 core 中的 QK 组合树抽成独立 engine，后续可直接替换成更深流水或阵列化实现。

2. **`fa_online_softmax_pair`**  
   - 职责：对当前两个 query row 完成 online softmax 的一次 pair update：
     - `m` 更新
     - `l` 更新
     - `acc` 重标定与 `P*V` 增量累加
   - 接口特点：
     - 参数化 `D`
     - 显式输入 `score / m_old / l_old / acc_old / v_row`
     - 显式输出 `m_new / l_new / acc_new`
   - 作用：把当前最关键的 softmax 反馈链从主控 FSM 中剥离出来，便于后续做 multi-context interleave、base-2 online softmax、ExpMul 融合等优化。

3. **`fa_o_normalize_block`**  
   - 职责：对一组 `NORM_LANES` 维度数据完成 `acc / l` 归一化与 Q8.8 饱和输出。  
   - 接口特点：
     - 参数化 `NORM_LANES`
     - 输入行为与当前 normalize 阶段完全对齐
   - 作用：把归一化 datapath 独立出来，为后续改成更深流水、base-2 归一化或共享除法近似路径做准备。

### 1.2 当前未继续拆分的部分

本次**暂不拆**以下部分：

- `fa_attention_core` 的 tile 级主状态机
- K/V prefetch 控制 FSM
- 顶层 DMA reader/writer / AXI-Lite regs

原因：

- 当前最主要的可优化热点在 datapath，而不是 tile 级控制流；
- 先保持 DMA / 顶层接口稳定，更利于行为等价验证；
- 前一阶段刚修复 write-side handshake 精度问题，当前不宜在控制面再做大改。

## 2. 为什么这 3 个边界是合理的

结合现有实现、历史 7 份报告以及 FlashAttention 1–4 的论文源码，可以把当前 core 视为三条强耦合但性质不同的路径：

1. **QK 点积路径**：规则、可并行、适合阵列化/流水化；
2. **online softmax 状态更新路径**：有反馈依赖，是时序与吞吐的主要矛盾点；
3. **最终 normalize / writeback 路径**：吞吐要求较低，但精度、舍入、握手语义很敏感。

这与历史报告中反复出现的结论一致：

- `report/20260306-miromind.md` 强调应先拆 `QKᵀ`、online softmax、normalize 三条路径；
- `report/20260306-chatgpt.md` 强调应把算子加速与调度重构分离评估；
- `report/chatgpt.md`、`report/miromind.md` 均指出在线 softmax 反馈链是最值得优先优化的部分；
- FlashAttention-1/2 的核心是 **IO-aware tiled exact attention + online merge**；
- FlashAttention-3 的重点是 **asynchrony / overlap / low precision**；
- FlashAttention-4 的重点是 **algorithm/kernel pipelining co-design**。

因此，先把 datapath 拆干净，再决定是否做更激进的 row-pipeline / engine decoupling，是当前仓库最稳妥的推进顺序。

## 3. 本次验证结果

### 3.1 已通过验证

本次拆分后，已完成并通过以下回归：

1. `make -C dv/cocotb MODULE=fa_attention_core`
   - 小参数快速回归通过

2. `make -C dv/cocotb MODULE=fa_attention_core_full`
   - 全参数 core 回归通过
   - 结果保持：
     - `RTL vs FP32: MAE = 0.005012`
     - `MAX_AE = 0.018949`

3. `make -C dv/cocotb MODULE=fa_attention_ip_top`
   - 顶层 4/4 全部通过
   - `test_perf_counters_full_run` 通过
   - 顶层数值结果保持：
     - `rtl vs fixed-q8.8 mae = 0.002053`
     - `rtl vs fp32 mae = 0.002490`
     - `rtl vs fp32 max_err = 0.006583`

### 3.2 验证结论

当前拆分属于**结构性重构、行为不变**，对之前修复过的：

- DMA split-burst 正确性
- top/core 数值一致性
- write-side `valid && ready` 语义

均未造成回退。

## 4. 对“还有没有其他模块有必要拆分”的判断

当前建议分两档：

### 4.1 现在就值得拆的

1. **`fa_attention_core` 主控与 prefetch 控制分离**  
   可继续把当前 core 内的：
   - tile scheduler
   - kv prefetch scheduler
   - compute issue scheduler
   再拆成 2~3 个 control 子模块。

2. **normalize + write path 再细分**  
   后续若要引入行间 overlap，可把：
   - reciprocal request/response 管理
   - normalize lanes
   - write packer
   分成三个小模块。

### 4.2 暂时不建议拆的

1. **`fa_dma_reader` / `fa_dma_writer`**  
   刚完成 burst legality 与顶层正确性闭环，当前优先保持稳定。

2. **`fa_axi_lite_regs`**  
   当前规模不大，收益有限。

3. **`fa_perf_counters`**  
   已是独立模块，边界足够清楚。

## 5. 基于 FlashAttention 1–4 与已有报告的优化方向

下面只列与当前仓库最相关、且能直接作用于新拆分子模块的方向。

### 5.1 对 `fa_qk_dotprod_slice` 的优化方向

#### 方向 A：从“组合归约”改为“短流水归约”

当前 `fa_qk_dotprod_slice` 仍是单拍组合归约。下一步可考虑：

- `DP_LANES=32` 保持不变；
- 内部做 2~3 级 pipeline；
- 用 row interleave 或 issue overlap 吃掉额外 latency。

依据：

- `report/20260306-miromind.md` 明确建议：高频化优先靠 pipeline + overlap，而不是只压组合路径；
- FlashAttention-3/4 的关键词是 async overlap 和 pipeline co-design，而不是单纯缩短单级逻辑。

#### 方向 B：阵列化/行列复用

如果后续愿意改动更大，可把这个模块发展为小型 systolic-like engine：

- 固定 `DP_LANES × ROW_PAR` 局部阵列；
- 行间共享 K broadcast；
- 后续直接对接 rowmax/rowsum 路径。

这更接近 FSA / FlashAttention-4 的方向。

### 5.2 对 `fa_online_softmax_pair` 的优化方向

这是**最高优先级**。

#### 方向 A：multi-context / multi-row interleave

当前每个 row context 仍是强反馈串行。建议下一步在该模块上尝试：

- 维护 2~4 个 row context slot；
- 把 `exp / rescale / acc update` 变成多上下文轮转；
- 用上下文交错隐藏内部流水深度。

依据：

- `report/20260306-miromind.md` 的任务 B 直接推荐 multi-context interleave；
- FlashAttention-3 的 asynchrony 思路，本质上也是把依赖隐藏在更粗粒度的调度里。

#### 方向 B：base-2 online softmax / Softermax 风格改写

把当前自然底 `exp` 路径改为：

- `exp(x) = 2^{x / ln2}`
- 用 `shift + 小 LUT/PWL` 替代当前 `exp_pwl`
- 尽量把 renorm 写成移位/短加法路径

收益：

- 组合路径更短；
- 更适合做多级流水；
- 更容易和 reciprocal / ExpMul 共享近似资源。

#### 方向 C：ExpMul 融合

把：

- `exp(diff_old) * acc_old`
- `exp(diff_new) * v`

重构为融合型 `ExpMul` 路径。

依据：

- `report/20260306-miromind.md` 与 `report/20260306-chatgpt.md` 都明确把 ExpMul 视为高价值方向；
- FlashAttention-4 的 co-design 也支持把 kernel 中最常见的组合子表达式改写为更适合流水的算子。

### 5.3 对 `fa_o_normalize_block` 的优化方向

#### 方向 A：normalize 与 write path overlap

当前 normalize 完全结束后才进入 `S_WRITE_O`。后续可尝试：

- row 级 normalize 完成后即进入 write FIFO；
- normalize 与 writeback 并行；
- 减少尾部 drain 时间。

#### 方向 B：reciprocal 的时序隐藏

当前 reciprocal 已是行级调用，但仍在 normalize 状态内部等待。后续可考虑：

- 提前发起下一行 reciprocal；
- 把 reciprocal 请求移动到更靠前的时机；
- 让 normalize lane 在拿到 reciprocal 时连续消费。

这与历史报告关于“把 reciprocal latency 隐藏在行间 overlap 中”的建议一致。

## 6. 下一阶段建议的 RTL 演进路线

### 阶段 1：已完成

- 把 monolithic datapath 拆成 3 个可独立演进的子模块；
- 保持全部行为与验证闭环不变。

### 阶段 2：建议下一步实现

1. 在 `fa_online_softmax_pair` 上引入 2-context interleave 原型；
2. 把 `fa_qk_dotprod_slice` 改成 2 级 pipeline；
3. 保持 top 接口与 cocotb 用例不变，验证是否能在不显著增 cycles 的前提下提升 STA 空间。

### 阶段 3：若阶段 2 成功

1. 把 core 控制面继续拆成：
   - tile scheduler
   - compute issue scheduler
   - prefetch scheduler
2. 再评估是否要做：
   - base-2 softmax
   - ExpMul
   - row-level normalize/write overlap

## 7. 可直接复制给 deep-research agent 的 prompt

下面内容可直接复制：

---

你正在研究一个面向端侧 SoC 的定点 FlashAttention RTL IP。请围绕“已完成 datapath 拆分后的下一阶段优化”做深入调研，并给出**可落地到当前工程**的结构建议。

### 项目背景
- 当前工程是 Q8.8 定点 attention IP，核心参数约为：`SEQ_LEN=256, D=64, TQ=32, TK=64, BUS_W=128`
- 顶层采用 AXI-Lite 控制 + AXI DMA 读写
- 当前 `fa_attention_core` 已做第一阶段拆分：
  - `fa_qk_dotprod_slice`：QK 点积 chunk engine
  - `fa_online_softmax_pair`：online softmax + acc update engine
  - `fa_o_normalize_block`：normalize lane block
- 当前拆分后行为已通过完整 cocotb 回归，顶层数值仍保持：`rtl vs fp32 mae ≈ 0.00249`

### 你的任务
请围绕以下问题开展调研，并输出“适合当前工程直接实现”的建议：

1. **online softmax engine 如何进一步流水化/交错化？**
   - multi-context / multi-row interleave 的最佳结构是什么？
   - 如何在不显著增加 cycles 的情况下隐藏 `exp / rescale / acc update` latency？
   - 对当前 Q8.8、ROW_PAR=2、D=64 约束下，context 数量建议多少？

2. **QK engine 如何从组合树演进到高频流水结构？**
   - 是否值得做 2~3 级 pipeline？
   - 如何通过调度把额外 latency 隐藏掉？
   - 是否存在“小型 systolic / reduction tree”比当前 chunk MAC 更合适？

3. **是否应把自然底 exp 改为 base-2 online softmax？**
   - 结合 Softermax、FlashAttention-3/4、硬件 softmax 论文，分析：
     - base-2 形式是否更适合 Q8.8 fixed-point
     - 对面积/Fmax/精度/控制复杂度的影响
   - 给出适合当前工程的小步演进方案，而不是完全推翻重写

4. **ExpMul 融合是否值得在当前工程引入？**
   - 当前 `exp(diff_old) * acc_old` 与 `exp(diff_new) * v` 是否适合融合
   - 融合后对精度、面积、Fmax、验证复杂度的影响
   - 若引入，应先替换哪一段路径

5. **normalize / reciprocal / writeback 如何进一步 overlap？**
   - reciprocal request 能否前移
   - normalize 和 writeback 是否可以 row-level overlap
   - 哪种微架构最适合当前 DMA 写接口与已有验证框架

### 参考资料范围
请重点结合：
- FlashAttention 1 / 2 / 3 / 4
- Online Softmax / Softermax
- SystolicAttention (FSA)
- FlatAttention
- 低成本 ExpMul / fixed-point exp / reciprocal 相关硬件论文
- 当前仓库已有报告：
  - `report/20260305-chatgpt.md`
  - `report/20260305-gemini.md`
  - `report/20260305-miromind.md`
  - `report/20260306-chatgpt.md`
  - `report/20260306-miromind.md`
  - `report/chatgpt.md`
  - `report/miromind.md`

### 输出要求
请输出：
1. 对当前工程最合适的 **3 个候选微架构**；
2. 每个候选方案对 `f_clk / cycles / area / 精度风险 / 验证复杂度` 的影响评估；
3. 推荐的实施顺序；
4. 尽量落到 RTL 级接口建议，例如新增哪些 pipeline register、context buffer、FIFO、状态机边界；
5. 给出“最小可验证原型”建议，优先考虑可以复用现有 cocotb 测试框架的方案。

---

## 8. 总结

本次已完成的是**第一阶段可验证拆分**：把 monolithic core 的 3 条关键 datapath 抽成独立 engine，同时保持全流程验证通过。下一阶段最值得投入的不是继续拆更多小模块，而是基于这些新边界，真正做：

- online softmax 交错/流水化
- QK engine 高频化
- normalize / reciprocal latency hiding

这三项才最可能同时改善后续 STA 空间与系统级 `f_clk / cycles`。