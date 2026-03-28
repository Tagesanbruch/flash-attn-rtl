# 2026-03-26 跨工程 Attention 加速器对比与优化路线（含 FlatAttention）

## 0. 结论先行（Executive Summary）

1. **当前项目（Q8.8 RTL 主线）**已具备“可交付 IP”特征：有统一寄存器接口、DMA/perf counters、端到端周期与误差闭环（当前主线约 `85.8k cycles` 量级）。
2. **FSA（2507.11331）**在“单阵列融合非 matmul attention 操作”方面非常强，且给出 FPGA 周期计数与误差；但其控制面是指令机生态、默认 FP16/FP32，和当前项目口径不完全一致。
3. **SpAtten（2012.09852）**是“稀疏注意力 + 专用硬件”的代表，给出完整 roofline、面积功耗与吞吐/能效；但算法是稀疏/剪枝范式，不是 exact dense FlashAttention。
4. **FlatAttention（2505.18824）**主要贡献在 dataflow + NoC collective 协同，强调“减少 HBM 流量、提升 tile 利用率”；是体系结构层面最值得借鉴的对照对象之一。
5. **hls-fpga-accelerators**当前仓库仅有模块化 HLS 内核与参数化脚本，**缺少统一公开 PPA/吞吐结果**，可作为“实现风格参考”，但暂不能作为“有数字结论”的强对照基线。

---

## 1. 比较口径与可比性约束

为避免“苹果 vs 橘子”式结论，本文先统一口径：

- 计算类型：dense exact / sparse approximate
- 数据格式：Q8.8 / INT8 / FP8 / FP16 / BF16
- 硬件形态：RTL IP / FPGA bitstream / GPU kernel / simulator model
- 指标类型：
  - 性能：cycles、延迟、吞吐、利用率
  - 带宽：HBM 或外部存储流量、利用率
  - PPA：频率、面积、功耗（能效）
  - 精度：MAE / MSE / MaxErr / PPL / 任务精度

**关键原则**：

1. 同一表内先比“同量纲指标”；
2. 非同量纲处显式标注“不可直接比较”；
3. 缺失数据保留空白，不做猜测外推。

---

## 2. 对比对象与证据来源

### 2.1 当前项目（flashattn）

- 源码与配置：`rtl/core/fa_attention_core.sv`、`rtl/bus/fa_axi_lite_regs.sv`
- 主线结果：`docs/data/20260311_rtl_summary_ctxstream.csv`
- 理论与分解：`docs/20260309_attention_core_theoretical_analysis.md`
- 当前 PPA 归纳：`docs/report_0324/10_逻辑综合与物理实现.md`

### 2.2 FSA / SystolicAttention（2507.11331）

- 工程：`ref/FSA/README.md`、`ref/FSA/python/fsa/config.py`、`ref/FSA/python/fsa/engine.py`
- 论文 tex：`papers/arXiv-tex/2507.11331/6-eval.tex`

### 2.3 SpAtten（2012.09852）

- 工程：`ref/spatten/README.md`、`ref/spatten/spatten_hardware/.../TestSpAtten.scala`
- 论文 tex：
  - `papers/arXiv-tex/2012.09852/texts/5_evaluation.tex`
  - `papers/arXiv-tex/2012.09852/tables/table_setup.tex`
  - `papers/arXiv-tex/2012.09852/tables/tab_power.tex`
  - `papers/arXiv-tex/2012.09852/tables/tab_compa3.tex`
  - `papers/arXiv-tex/2012.09852/macros.tex`

### 2.4 FlatAttention（2505.18824）

- 论文 tex：
  - `papers/arXiv-tex/arXiv-2505.18824v1/paper.tex`
  - `papers/arXiv-tex/arXiv-2505.18824v1/glossary.tex`

### 2.5 其他参考

- SageAttention（GPU kernel）：`ref/SageAttention/README.md`
- HLS FPGA kernels：`ref/hls-fpga-accelerators/README.md` 与各子模块 `*.tcl`

---

## 3. 关键规格与结果总表（论文式汇总）

> 说明：空白项表示当前仓库/论文文本中未给出可直接摘录的统一数字。

| 工作 | 计算范式 | 主要数据格式 | 硬件/平台 | 关键性能结果 | 带宽/流量结果 | PPA结果 | 精度结果 |
|---|---|---|---|---|---|---|---|
| 当前项目（flashattn主线） | Dense, online softmax, tile streaming | Q8.8（内部混合宽度） | RTL IP（AXI-Lite + AXI DMA） | `total_cycles≈85808`（S=256,D=64主线） | 历史闭环样例 `bus_util≈25.3%`（145k周期口径）；当前主线有 rd/wr 分项计数 | leaf级 STA：QK约 `442.5MHz`、softmax ctx约 `536.2MHz`、recip约 `526.7MHz`、norm约 `360.8MHz` | 主线 summary 给出 `rtl_fp32_mae` / `rtl_fp32_maxae` |
| FSA（2507.11331） | Dense，单SA融合 attention 所有子算子 | FP16 mul / FP32 acc（可配） | Chipyard+RTL/FPGA(U55C) | README示例：`Execution time=9414 cycles`（seq_q=16,seq_kv=16样例） | 同样例给出 bubble/active/DMA cycles、指令计数 | 论文强调与商业SA对比利用率；工程层公开实例未给统一面积表 | README样例给 MAE/MSE/MaxErr/RelErr（vs torch） |
| SpAtten（2012.09852） | Sparse（token/head pruning + progressive quant） | 多 bitwidth（含12-bit路径） | RTL+Verilator+HBM仿真，40nm 综合估计 | 宏值：BERT约 `1.61 TFLOPS`，GPT2约 `0.43 TFLOPS` | Roofline中 HBM 512GB/s；给出 DRAM 访问压缩倍数（宏值） | `area=18.71 mm²`，`power=8.30W`（logic+SRAM+DRAM分解） | 任务级精度/tradeoff 曲线（允许极小精度损失配置） |
| FlatAttention（2505.18824） | Dense，Flat dataflow + NoC collectives | FP16（1GHz建模） | Tile-based many-PE 模型（SoftHier/GVSoC） | 文中宏值：相对FA-3在同类tile架构 **最高约4.1×** speedup，利用率最高 `89.3%` | HBM traffic 最高约 **16×** 减少（宏值） | 通过GE估算给出 best arch die 约 `457 mm²`（与H100同节点估算） | 侧重性能/体系结构，不是误差主导论文 |
| SageAttention（参考） | 近似/量化 attention kernel（GPU） | INT8 QK + FP8/FP16 PV（多变体） | CUDA/Triton（A/H/BW GPUs） | README给多平台 speedup/TOPS 图 | 非RTL片外带宽口径，主要是GPU kernel表现 | 不提供芯片PPA | 强调“高精度保持”与端到端精度图 |
| hls-fpga-accelerators（参考） | 模块化 kernel（matmul/softmax/rmsnorm等） | FLOAT4~32 / FIXED8~16 可配 | Vitis HLS（U250/K26） | 当前仓库未提供统一 benchmark 结果表 | 未给统一内存流量统计表 | 仅见 `create_clock -period 300MHz` 约束；缺少综合产物提交 | 未给任务级精度对比 |

---

## 4. 与当前项目最相关的“RTL硬件实现差异”

## 4.1 当前项目 vs FSA

共同点：

- 都是 attention 专用硬件化路径；
- 都强调在线 softmax / tile 级调度与片上复用；
- 都有周期计数和误差对照。

关键差异：

1. **控制面范式**
   - 当前项目：固定寄存器映射 + 启停 + perf regs（IP 形态）
   - FSA：指令队列/执行计划（更接近可编程加速器）
2. **数据格式**
   - 当前项目：Q8.8 固定点主线
   - FSA：FP16/FP32 混合主线
3. **系统定位**
   - 当前项目：比赛约束下的可集成 IP
   - FSA：Chipyard生态下的架构研究原型 + FPGA落地

工程启示：

- FSA 强项在“融合与调度方法论”，可用于指导当前项目下一轮系统重构；
- 但不能把 FSA 的周期/误差数字直接当作当前 IP 的横向胜负结论。

## 4.2 当前项目 vs SpAtten

共同点：

- 都有 RTL/硬件实现导向；
- 都给 roofline 或近似 roofline 分析；
- 都关注带宽与数据搬运。

关键差异：

1. **算法定义不同**：当前项目是 dense FlashAttention 路线；SpAtten 是稀疏剪枝路线。
2. **收益来源不同**：
   - 当前项目：pipeline/数据流重叠、固定点算术、模块时序收敛；
   - SpAtten：token/head pruning + progressive quantization 大幅降低 DRAM/计算量。
3. **可比指标**：
   - 可比：面积功耗量级、roofline位置、带宽敏感性趋势；
   - 不可直接比：同任务精度下的“绝对吞吐”若未统一稀疏策略与精度约束。

工程启示：

- SpAtten 的 top-k 硬件、稀疏调度与多级带宽治理值得作为 bonus 分支参考；
- 若引入其思想，必须单独标注为“算法改变分支”，避免和 dense baseline 直接混算。

## 4.3 当前项目 vs FlatAttention（2505.18824）

FlatAttention 的核心价值不在某个 leaf 算子，而在：

1. **将 tile group 作为统一数据复用体**，把更多复用从 HBM 迁移到片上网络；
2. **显式利用 NoC collective primitives（multicast/reduce）** 降低同步和搬运代价；
3. **算法-架构共同探索**，针对不同序列长度选择最优 flatten scale，避免 over-flattening。

对当前项目可执行的映射：

- 若后续进入多核/多阵列扩展，FlatAttention 是比“单核局部优化”更高 ROI 的系统参考；
- 即便单 IP 场景，也可借鉴其“通信/计算 overlap 与块尺寸共同优化”的分析框架。

---

## 5. 对 hls-fpga-accelerators 与 ref/spatten 的专项补充

## 5.1 hls-fpga-accelerators（你指定项）

现状结论：

- 有完整模块族与参数化维度（datatype、bus width、矩阵规模、目标器件）；
- tcl 里给出统一目标时钟约束（300MHz）；
- 但仓库中未附带稳定统一的 csynth/cosim 报告归档（LUT/FF/DSP/BRAM/Latency 等总表缺失）。

因此在本文对比里：

- 将其定位为“可复用实现模板与参数空间参考”；
- 在“有数值的论文式 PPA 对照”中暂留空。

## 5.2 spatten（你指定项）

可直接用于论文式对照的硬指标非常充分：

- 体系结构参数（table_setup）；
- 面积功耗（tab_power + macros）；
- 吞吐/能效/面积效率（tab_compa3）；
- roofline（文本给 512GB/s、2TFLOPS 理论顶线和实测点）。

这使其成为“RTL/硬件实现基线”中最完整的参照之一。

---

## 6. 当前架构的优化空间：延迟、吞吐、算力

结合当前主线数据（`~85.8k cycles`、compute 占主导）与前述外部工作，建议分三层推进。

## 6.1 近程（不改算法定义，保持 dense）

1. **QK 路径**：继续压输入扇出与乘法叶级关键路径，目标从 ~442MHz 逼近 500MHz；
2. **Normalize 路径**：部分积树与符号/饱和路径解耦，减少单拍混合逻辑；
3. **系统重叠**：优先提升 core 中流式发射与回收效率，避免 leaf 频点收益被控制气泡抵消。

## 6.2 中程（轻度架构扩展）

1. `S=512/valid_len` 的 DMA 裁剪与 bytes/cycle 优化；
2. multi-head / task queue 的控制面扩展，建立吞吐可伸缩性基线；
3. 引入更细粒度 perf counter（issue/retire stall 分类）强化瓶颈归因。

## 6.3 远程（算法-架构协同）

1. 借鉴 FlatAttention 的分组复用思想（若进入多tile/多核路径）；
2. 选择性引入 SpAtten 式稀疏策略作为独立分支（明确“非dense基线”标签）；
3. 数据格式扩展（BF16/INT8-FP8）与密集路线并行验证。

---

## 7. 能否通过 CModel 或数学模型进行参数分析？

可以，且应分为两类：

## 7.1 CModel/仿真可扫参数（离散、实现相关）

- tile 参数：`TQ/TK/ROW_PAR/DP_LANES/NORM_LANES`
- pipeline 参数：QK latency、softmax context 数、normalize chunk
- DMA 参数：burst 组织、prefetch 窗口
- 近似参数：exp/recip 配置、rounding 策略

输出指标建议统一：

- `cycles`
- `GOPS/GHz`
- `bytes/cycle`
- `bus_util`
- `error (MAE/MaxAE)`

## 7.2 数学模型可扫参数（连续、体系结构相关）

- 总周期近似：

$$
T \approx T_{load} + T_{compute} + T_{norm} + T_{write} - T_{overlap}
$$

- 计算上界（按 score-pair 与 lane）
- 带宽下界（按总字节与总线宽度）
- 资源模型（面积/功耗按模块加权）

建议采用“模型预测 → 小规模 RTL/CModel 点验证 → 修正系数”闭环，而不是纯公式外推。

---

## 8. Roofline 分析：当前可做与建议补齐

## 8.1 现在就可构建的工程化 Roofline

可定义：

- 纵轴：`Effective Compute Throughput (GOPS or equivalent)`
- 横轴：`Arithmetic Intensity = Ops / Byte`
- 带宽屋顶：`BW_peak`
- 算力屋顶：`Peak_compute`

当前项目已具备关键输入（cycles、bytes、模块分解），可先做“工程 Roofline 草图”。

## 8.2 与论文式 Roofline 的差距

- 仍缺稳定统一的“总 ops 口径”（尤其 fixed-point dense attention 各阶段如何折算）；
- 仍缺多工作点系统性扫描（多 S、多 D、多 mask/valid_len）。

## 8.3 建议的最小补齐实验集

1. `(S,D) ∈ {(256,64),(512,64),(1024,64)}`；
2. 每点导出 `cycles, rd_bytes, wr_bytes, compute sub-cycles, error`；
3. 在同一脚本中生成 roofline 点云与瓶颈分类（compute-bound / bw-bound）。

---

## 9. 当前“论文式对比”可直接引用的核心数字（摘录）

### 9.1 当前项目

- 主线周期：`~85.8k`（S=256,D=64）
- compute 子项：`dp=66560`、`score=32768`、`softmax=32768`
- 示例 bus 利用率（历史闭环口径）：`~25.3%`

### 9.2 FSA

- 示例 FPGA 计数：`Execution=9414 cycles`（seq16×16 样例）
- 示例误差：MAE/MSE/MaxErr/RelErr 已给

### 9.3 SpAtten

- Full 版：`18.71 mm²`、`8.30 W`
- Throughput（宏值）：BERT `1.61 TFLOPS`，GPT2 `0.43 TFLOPS`
- Roofline：理论算力顶 `2 TFLOPS`，带宽顶按 `512GB/s`

### 9.4 FlatAttention

- 同类 tile 架构下：相对 FA-3 最高约 `4.1×` speedup
- HBM traffic 最高约 `16×` 降低
- best arch 估算：`457 mm²`（同节点估算口径）

---

## 10. 诚实说明（当前仍缺的数据）

1. `hls-fpga-accelerators` 仓库内缺统一可复核的综合/时序/吞吐报告表，无法给出“硬数值排名”。
2. 当前项目尚缺“顶层统一工艺口径”的完整后端签核 PPA（当前以 pre-P&R/leaf 为主）。
3. FlatAttention 的公开材料以建模/模拟为主，不等同于开源 RTL 实测。
4. 跨工作“绝对吞吐”若未统一算法定义（dense vs sparse）、精度、batch/seq、工艺节点，不应直接下结论。

---

## 11. 下一步建议（可执行）

1. 在本仓库新增一份 `comparison_data.csv`，固化各工作可比字段与来源；
2. 用现有脚本生成“当前项目 roofline 点云 + 参数扫描图”；
3. 若需要对外展示，建议拆成两张表：
   - `Table-A`：dense exact 路线（当前项目/FSA/FlatAttention）
   - `Table-B`：sparse/quant 路线（SpAtten/SageAttention）

这样能最大程度避免口径混淆，同时保留论文式完整性。

---

## 12. “是否存在代差？”——针对你关心的 9414 vs 8w+ vs 2.15M 的归一化判断

先给结论：

1. **仅看绝对 cycles（9414 vs 85808）会严重误判**，因为问题规模不同（`S=16` vs `S=256`，计算量按 $S^2$ 增长）；
2. 在“每个 score-pair 对应 cycles”口径下，当前 Q8.8 主线并不落后，反而明显优于 README 中 FSA 小规模样例；
3. BF16 分支的 `~2.15M cycles` 主要说明该分支仍处在“功能/结构探索态”，**不能**拿来代表主线工程代际水平。

### 12.1 为什么会产生“百倍差距”的错觉

你提出的担心完全合理：看到 FSA 的 `9414 cycles`，再看当前主线 `~85.8k cycles`，直觉上会觉得差了一个数量级。

但 FSA README 该数字来自 FPGA 示例：`seq_q=16, seq_kv=16`；当前主线口径是 `S=256, D=64`。在 dense attention 中，核心计算规模近似与 $S^2$ 成正比：

$$
   ext{Work} \propto S_q\times S_{kv}\times D
$$

所以将 `S=16` 与 `S=256` 直接比 cycles，本身就会把规模差误读成架构差。

### 12.2 同口径归一化：cycles / (S_q \times S_{kv})

定义：

$$
   ext{pair-cycle} = \frac{\text{total cycles}}{S_q\times S_{kv}}
$$

- 当前主线（Q8.8, `S=256`）：
   - $85808 / (256\times256) \approx 1.31$ cycles/pair
- FSA README 示例（`S=16`）：
   - $9414 / (16\times16) \approx 36.77$ cycles/pair
- BF16 分支（`exp/bonus1-bf16`, `~2,150,497 cycles`, 同主线规模口径）：
   - $2{,}150{,}497 / (256\times256) \approx 32.81$ cycles/pair

这组数字说明：

1. 当前主线 Q8.8 与 FSA README 小样例相比，按 pair-cycle 不是落后而是更低；
2. BF16 分支的 pair-cycle（~32.8）与 FSA README 小样例（~36.8）处于同一数量级；
3. 因而“我们比别人慢百倍”这个结论在现有证据下不成立。

### 12.3 反向 sanity check：把 FSA 小样例按 $S^2$ 粗扩到 S=256

若仅做最粗略的 $S^2$ 比例外推（忽略常数项和实现差异）：

$$
9414 \times (256/16)^2 = 2{,}409{,}984
$$

得到约 `2.41M cycles`。这个量级与当前 BF16 分支（`~2.15M`）接近，而与当前 Q8.8 主线（`~85.8k`）相差较大。

这进一步说明：FSA README 的 `9414` 更像“小规模示例 + 特定配置”数字，不应直接解读为在你当前目标规模上的绝对优势。

### 12.4 面积/PPA角度：是否支持“代差”判断

现有证据仍不足以得出“代差”结论：

1. FSA 论文给出的面积拆分是 `128x128` 阵列、`16nm`、且注明不含 SRAM/DMA 的局部统计；
2. SpAtten 是 `40nm`、稀疏算法路径，面积/功耗完整但算法定义不同；
3. 当前项目尚缺顶层同工艺同边界（含/不含 SRAM、DMA）的一致签核面积表。

因此，当前阶段最稳妥表述应是：

- **性能合理性**：在目标规模 `S=256,D=64` 下，当前 Q8.8 主线 `~85.8k cycles` 处于合理且有竞争力的区间；
- **非代差证据**：归一化 pair-cycle 不支持“百倍落后”；
- **后续要补**：统一边界的顶层 PPA（含面积）后，才能给“代际”做更强结论。

### 12.5 建议的正式对外口径（可直接复用）

建议在报告中固定以下措辞：

> FSA/SpAtten/FlatAttention 与本工程在算法定义、问题规模、数据格式与实现边界上存在显著差异。若仅比较绝对 cycles 容易产生“代差”误判。按 `cycles/(S_q×S_{kv})` 等归一化口径评估，本工程主线性能处于合理范围，不支持“百倍性能落后”的结论；后续将通过统一边界的顶层 PPA 与多工作点 roofline 进一步收敛对比结论。

---

## 13. 一页归一化对比：时空复杂度视角（回答“为什么 S=512 约 4x”）

### 13.1 本工程当前主线的复杂度结论

在保持 dense exact attention 定义不变时，核心时间复杂度仍是：

$$
T = O(S^2\cdot D)
$$

空间复杂度方面，由于不显式存储 $S\times S$ score 矩阵，片上主要是 tile/cache 与行状态，工程上可写成：

$$
M \approx O(S\cdot D) + O(TQ\cdot TK)\ (\text{buffers})
$$

这也是为什么你看到：

- `S=256`: `cycles=85928`
- `S=512`: `cycles=307024`

比例为：

$$
\frac{307024}{85928} \approx 3.57
$$

接近 $4$ 但略低于 $4$，符合“主导项 $O(S^2)$ + 固定开销摊薄”的实测特征。

### 13.2 归一化表（可直接放报告）

| 口径 | S / 条件 | cycles | 归一化指标 | 解读 |
|---|---:|---:|---:|---|
| 当前主线 Q8.8 | `S=256,D=64` | `85,808` | `1.31 cycles/pair` | dense 主线基准 |
| 当前主线 Q8.8 | `S=512,D=64` | `307,024` | `1.17 cycles/pair` | S 翻倍后 pair 成本略降，固定开销被摊薄 |
| FSA README 示例 | `S=16` | `9,414` | `36.77 cycles/pair` | 小规模示例，不能直接横比 |
| BF16 bonus 分支 | 与主线同规模口径 | `2,150,497` | `32.81 cycles/pair` | 原型分支，尚未主线化 |

> 其中 `cycles/pair = cycles/(S_q\times S_{kv})`。

### 13.3 “降常数”与“降数量级”的区别（避免误解）

1. **降常数（不改 $O(S^2)$）**
   - 代表：FlashAttention 类 dataflow、FSA 的融合调度、FlatAttention 的 dataflow+fabric 协同。
   - 作用：显著降低常数项（访存、同步、流水空拍），但主导项仍与 $S^2$ 相关。

2. **改数量级（目标亚二次/线性）**
   - 代表路线：
     - 稀疏/剪枝（如 SpAtten 思路）：将有效 pair 数降到 $\rho S^2$；
     - 核函数/低秩近似（经典如 Linear Transformer / Performer / Nyström 系）；
     - 块稀疏或检索式 attention（按命中块数缩减有效计算）。
   - 代价：通常引入近似误差、任务相关退化风险或更复杂的硬件控制。

### 13.4 针对你问题的直接回答

1. 看到 `9414` 再看 `8w+`，会误以为“代差很大”，这是**正常直觉**，但在不同 `S` 下并不成立；
2. 你现在 `S=512` 约 `3.57x` 的结果，正是 dense 路线接近 $O(S^2)$ 的典型表现，不是异常；
3. BF16 分支 `~2M` 说明“该分支尚未像主线一样完成架构收敛”，而不是主线整体代际落后；
4. 若目标是从根上摆脱平方增长，需要把“稀疏/近似”作为独立路线，并单独给精度-性能曲线，不与 dense baseline 混写。
