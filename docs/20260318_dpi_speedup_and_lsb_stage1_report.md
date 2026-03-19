# 2026-03-18 DPI仿真提速可行性与+2LSB阶段定位（Stage-1）

## 1. 目标

根据当前联调状态，补充两部分内容：

1) DPI+Verilator链路是否有可实施的提速空间；  
2) +2 LSB 偏差的第一阶段定位结果。

---

## 2. DPI仿真速度：现状与瓶颈

## 2.1 观测现状

- 非DPI运行（run_fa）对 prompt=hello 的实测：
  - prefill tok/s = 35.799522
  - decode tok/s = 37.974682
- DPI运行在手动SIGINT样本中，尚未进入decode输出阶段。

说明：当前DPI路径的端到端速度与SW路径存在数量级差距。

## 2.2 主要瓶颈分解

结合代码路径，瓶颈主要来自：

1) **任务粒度过细 + 串行提交**  
   目前每个head单独 submit + wait_idle，缺少“多head队列批提交后集中等待”的利用方式，导致队列深度优势未充分发挥。

2) **软件参考difftest成本高**  
   每个head都运行 SW 参考 + 比对；在长序列阶段会显著放大CPU开销。

3) **trace写盘频繁刷新**  
   差异trace每条都写文件并刷新，I/O开销较重。

4) **Verilator模型本身为软件仿真**  
   即使-O3，也受限于主机单进程执行与总线握手模拟开销。

## 2.3 可执行提速建议（按收益/风险排序）

### P0（建议先做，改动低风险）

- **difftest降采样**：提供按 layer/head/pos 采样开关，只对抽样点做SW参考。  
- **trace缓冲落盘**：改为批量flush（例如每N条或退出时flush）。  
- **调试信息分级**：默认仅summary，细粒度trace按环境变量开启。

预期收益：1.5x~3x（视当前trace开关使用强度）。

### P1（中等改动）

- **head批量提交**：每层按FIFO_DEPTH批量enqueue，再统一wait_idle。  
- **减少不必要的寄存器轮询频度**：增大poll step，降低host端空转比例。

预期收益：2x~5x（与当前串行submit-wait模式相比）。

### P2（结构性优化）

- **层内任务融合策略**：减少host↔RTL交互次数。  
- **更细粒度性能计数器闭环**：用计数器驱动自动调参（批量深度、poll间隔、比对频率）。

---

## 3. +2LSB阶段定位：Stage-1实验

## 3.1 新增实验程序

新增 `inference/dpi/tests/dpi_lsb_stage_compare.cpp`，在 `seq_len=0` 最小场景下，
用同一组输入分别比较以下参考语义与RTL输出差异：

- 量化模式：trunc / floor / nearest
- 归一化eps：on(1e-6) / off(0)

## 3.2 实测结果

运行结果摘要：

- cand=0 trunc+eps_on：max_abs=2，sum_abs=90
- cand=1 trunc+eps_off：max_abs=1，sum_abs=30
- cand=2 floor+eps_on：max_abs=1，sum_abs=60
- cand=3 floor+eps_off：max_abs=1，sum_abs=30
- cand=4 nearest+eps_on：max_abs=1，sum_abs=30
- cand=5 nearest+eps_off：max_abs=1，sum_abs=30

best_candidate=1（trunc + eps_off）

## 3.3 阶段结论

结论A：当前看到的 +2 LSB 中，至少有一部分来自参考模型与RTL在归一化语义上的不一致（`+1e-6` 项）。  
结论B：去掉eps后误差上限降到1 LSB，剩余1 LSB更可能是量化舍入策略差异（trunc/floor/nearest等价类问题）。

---

## 4. 下一步（Stage-2）

建议直接进入：

1) 在 `seq_len=0` 下进一步固定归一化语义，逐项验证量化舍入策略，确认“最后1LSB”的唯一解释。  
2) 将该语义回灌到 `flash_attn.c` 的参考路径，验证 `max_abs` 是否从2稳定收敛到1或0。  
3) 再扩展到 `seq_len=1/2`，确认结论在多步场景仍成立。

---

## 5. 小结

- 仿真速度：存在明确可落地提升空间，先从P0/P1可见收益项做。  
- LSB定位：已完成Stage-1，确认“eps语义不一致”是+2LSB的重要来源；剩余问题收敛到1LSB量化细节。

---

## 6. P0已落地改造与手动实测结果（新增）

## 6.1 已落地P0代码项

已在 native 路径实现三项低风险加速开关：

1) difftest降采样：`FLASH_ATTN_DPI_DIFFTEST_SAMPLE_EVERY`  
2) trace批量flush：`FLASH_ATTN_DPI_DIFF_FLUSH_EVERY`  
3) wait poll步长可调：`FLASH_ATTN_DPI_POLL_STEP_CYCLES`

并补充退出时总运行时长打印：`Run Elapsed(s)`，用于手动Ctrl+C场景下的速度估算。

## 6.2 三组手动Ctrl+C实测

说明：在中断场景下，`prefill tok/s` 会因为统计口径（固定用prompt token数）出现偏差，因此本节采用

- 真实运行时长：`Run Elapsed(s)`
- 近似已处理token：`Matmuls / 169`（每个token约169次matmul）

进行估算。

### Case-A：全量difftest（sample=1）

- Run Elapsed(s) = 183.797
- Matmuls = 845 -> 约 5 token
- 粗估速度：约 36.8 s/token
- diff summary：run=1476，total_mismatch=1476

### Case-B：降采样difftest（sample=8）

- Run Elapsed(s) = 55.218
- Matmuls = 338 -> 约 2 token
- 粗估速度：约 27.6 s/token
- diff summary：run=443，total_mismatch=64

### Case-C：关闭difftest

- Run Elapsed(s) = 266.475
- Matmuls = 1183 -> 约 7 token
- 粗估速度：约 38.1 s/token
- diff summary：total_mismatch=0（因为关闭了difftest）

## 6.3 对“多久能进decode”的更新估算

以 prefill 约30 token 估算，当前观测对应的首decode时间量级约：

- sample=1：约 18~25 分钟
- sample=8：约 14~20 分钟（样本更短，误差较大）
- no_difftest：约 19~26 分钟

结论：当前瓶颈主要仍在 RTL attention 仿真本体，P0对“统计/比对开销”有帮助，但未带来数量级改善。

## 6.4 “有误差情况下 token 是否正常”检查结论

已补做“跑到decode阶段”的长跑验证（sample=8, assert_off, difftest_on）：

- Run Elapsed(s) = 2597.926
- Tokens: prefill=30, decode=31
- diff summary: total_mismatch=2965, run=20749

终端现象：`Answer:` 后主要表现为空行（大量换行），未观察到稳定可读的文本token。

结论更新：

- **有误差场景下，当前token输出可读性不正常（至少在该配置与样本下）**。
- 这与前述 +2LSB 及更高幅度偏差（部分head已出现更大误差）是一致的。

## 6.5 对“多久能进decode”的更新（有真实decode样本）

基于长跑样本中的吞吐：

- prefill tok/s = 0.023800
- decode tok/s = 0.023179

可得：

- 预计到首个decode token约需 `30 / 0.0238 ≈ 1260s ≈ 21分钟`
- 当前全程速度量级约 `0.023 tok/s`（极慢）

备注：

- 该估算比短窗口中断样本更可信，因为已经跨过prefill并进入decode阶段。

---

## 7. 可读性根因定位（新增）

## 7.1 为快速定位增加的调试开关

在 `run_fa.c` 增加了以下运行时开关：

- `RUN_FA_SIMPLE_PROMPT=1`：跳过chat模板包装，直接编码原始prompt，显著缩短prefill。  
- `RUN_FA_DEBUG_DECODE_TOKENS=1`：在decode阶段打印 token id 与 piece。  
- `RUN_FA_SYSTEM_PROMPT`：可覆盖默认system prompt。  
- `RUN_FA_STEPS`：可覆盖默认步数。

并将日志统一存放到：`inference/native/logs/`。

## 7.2 DPI vs SW 对照实验（同一简化prompt）

实验设置：

- prompt = `hello`
- `RUN_FA_SIMPLE_PROMPT=1`
- `RUN_FA_DEBUG_DECODE_TOKENS=1`

### SW结果

- decode token序列正常、语义连贯（如 `, how are you ? ...`）。

### DPI结果（difftest sample=8）

- decode阶段出现重复token：
   - `token=72030`, `piece='/API'`
   - 连续重复输出 `/API /API /API ...`

## 7.3 定位结论

可读性问题不是“终端打印乱码”层面，而是模型输出分布已经偏离到**模式坍缩**：

- 在有误差场景下，logits主导token发生异常集中，导致重复采样同一token。  
- 与 `fa_diff_trace.log` 中随pos增长快速放大的 `max_abs_lsb`（最高已到 2000+）一致。

因此，下一步应优先做：

1) 在 decode 首步记录 top-k logits（SW vs DPI）差异；  
2) 将 +2LSB/量化语义修正（Stage-2）回灌后复测 token 可读性。

## 7.4 logits top-k 对照结果（已完成）

已在同一实验条件下完成 SW vs DPI 的 top-k 对照：

- 条件：`RUN_FA_SIMPLE_PROMPT=1`，`RUN_FA_DEBUG_TOPK=5`，`RUN_FA_DEBUG_DECODE_TOKENS=1`
- 输出文件：
   - `inference/native/logs/sw_decode_debug.log`
   - `inference/native/logs/dpi_decode_debug.log`

### SW侧

- top-k 随 pos 正常变化。  
- decode token序列为自然语言片段（例如 `,`、` how`、` are`、` you`、`?`）。

### DPI侧

- pos=1 时 top-1 即出现 `72030:/API`，且随后的 decode 多步重复采样同一token。  
- 关键片段：
   - `decode pos=2 token=72030 piece='/API'`
   - `decode pos=3 token=72030 piece='/API'`
   - `decode pos=4 token=72030 piece='/API'`
   - `decode pos=5 token=72030 piece='/API'`

结论：

- 可读性异常已从“现象级”收敛为“logits分布级”证据：DPI路径在decode早期出现主导token异常集中（mode collapse）。

---

## 8. 首层首步中间量抓取（新增）

已新增 `FLASH_ATTN_DPI_STAGE_DEBUG` 抓取通道，在 `seq_len=0, head=0` 记录：

- 首步QK打分：`score_acc`、`score_f32`、`scale`  
- 输入片段：`q0..7`、`k0..7`、`v0..7`  
- 输出片段：`o_rtl0..7`、`o_ref0..7`  
- 首差信息：`max_abs_lsb/max_idx`

日志文件：`inference/native/logs/dpi_stage_debug.log`

当前观测到的共性：

- 在最小场景下，`o_rtl` 相对 `o_ref` 仍稳定出现 1~2 LSB 级别偏差；  
- 多组样本中 `max_abs_lsb=2` 反复出现；  
- 与前述Stage-1结论一致：基础偏差在早期就存在，后续随序列推进会被放大，最终影响decode可读性。

---

## 9. Stage-2量化修正尝试与结果（新增）

本轮尝试了“参考归一化语义收敛”（去掉 `flash_attn.c` 参考路径中的 `+1e-6` 项）后复测可读性。

### 9.1 结果

- `/API` 重复采样现象仍然存在。  
- `logs/dpi_decode_debug.log` 与 `logs/dpi_decode_debug_after_stage2.log` 对照显示：
   - decode首步仍采样 `token=72030 (/API)`；
   - top-k分布仍出现异常集中。

### 9.2 结论

- 该Stage-2改动主要影响“参考比对语义”，对DPI真实输出路径几乎无直接修复作用；  
- 可读性坍缩的主因仍在 RTL 路径/中间值放大链路本体，不是这一步参考语义造成的。

### 9.3 下一步建议

优先进入“首步 decode logits 生成链路”定位：

1) 在首层首步比较 SW vs DPI 的 attention输出范数与极值；  
2) 对比进入 logits 前最后一层激活统计（均值/方差/最大绝对值）；  
3) 锁定“从轻微LSB偏差到大幅分布坍缩”的放大节点。

---

## 10. Attention输出范数链路对照（新增）

按你的选择，已完成 `pos=1` 的逐层 attention 输出范数对照：

- SW日志：`inference/native/logs/attn_norm_sw_pos1.log`
- DPI日志：`inference/native/logs/attn_norm_dpi_pos1.log`

观测摘要：

- 早层（layer 0~10）存在偏差，但量级尚可（非瞬时爆炸）。  
- 中后层差异逐步放大，末层更明显：
   - layer23: SW `l2=53.93`, DPI `l2=66.13`（约 +22.6%）
   - layer23: SW `rms=1.80`, DPI `rms=2.21`
   - maxabs 也在末层抬高（SW `6.98` -> DPI `7.83`）

结论：

- 目前更像“逐层累积放大”而不是“单一层瞬时失控”；  
- 与 logits top-k 坍缩（`/API`重复）一致：早期已有偏差，后期被放大到可读性失真。

---

## 11. logits前最后激活统计（新增）

已完成 `final rmsnorm` 后、`wcls matmul` 前的统计对照（`pos=1`）：

- SW: `mean=0.174285`, `std=7.918136`, `maxabs=78.351021`  
- DPI: `mean=-0.005735`, `std=8.088543`, `maxabs=105.493462`

文件：

- `inference/native/logs/final_act_sw_pos1.log`
- `inference/native/logs/final_act_dpi_pos1.log`

结论：

- 在进入 logits 之前，DPI 激活分布已经出现明显幅值抬升（maxabs 约 +34.6%）；  
- 这与 top-k 坍缩（`/API`重复）是同一链路上的上游证据，说明问题在 logits 之前已形成。

---

## 12. 逐层修复试验（A/B）结果（新增）

为验证“幅值放大是否主因”，新增实验开关：

- `FLASH_ATTN_DPI_OUT_GAIN`：对 DPI attention 输出施加增益（试验用途）

在同一简化条件下（`RUN_FA_SIMPLE_PROMPT=1`，首个decode token即停）测试：

- gain=1.0 -> `token=72030`, `piece='/API'`
- gain=0.8 -> `token=72030`, `piece='/API'`
- gain=0.6 -> `token=17`, `piece='2'`

对应文件：

- `inference/native/logs/gain1_decode_debug.log`
- `inference/native/logs/gain08_decode_debug.log`
- `inference/native/logs/gain06_decode_debug.log`

结论：

- 简单的输出增益下调能够改变坍缩token，说明“幅值链路异常”是主因之一；  
- 但这仍是补偿性修复，不是根因修复（需要回到 RTL/量化链路本体定位）。

---

## 13. 头级热点定位（新增）

基于 `FLASH_ATTN_DPI_HEAD_SUMMARY=1` 日志：

- 文件：`inference/native/logs/dpi_head_summary.log`
- `pos=1` 共有 336 条记录（24层 × 14头）

按 `max_abs_lsb` 排序的热点（节选）：

- head=1: `max_abs_lsb=512`, `rtl=-325`, `ref=187`
- head=8: `max_abs_lsb=468`, `rtl=445`, `ref=-23`
- head=11: `max_abs_lsb=426`, `rtl=445`, `ref=19`
- head=12: `max_abs_lsb=425`, `rtl=445`, `ref=20`
- head=7: `max_abs_lsb=419`, `rtl=445`, `ref=26`
- head=10: `max_abs_lsb=413`, `rtl=445`, `ref=32`

观察到的模式：

- 并非所有head均匀发散，而是存在明显“头级热点”；  
- `head=1` 与 `head=8~13` 反复出现大误差，且常伴随符号翻转（正负方向不一致）。

这进一步支持：

- 当前问题不是纯随机噪声，而是某些头/路径上的系统性失配。

---

## 14. 层级热力图报告（新增）

已基于 `pos=1` 的 head summary 日志生成“24层 × 14头”热力图数据：

- 热力图矩阵CSV：`inference/native/logs/head_heatmap_pos1.csv`
- 报告明细（Top20 + 全矩阵）：`docs/20260319_head_heatmap_pos1.md`

### 14.1 层级聚类结论

按每层 `max_abs_lsb` 求和（14头）统计：

- layer23: sum=5091, max=512
- layer22: sum=3941, max=349
- layer1:  sum=2183, max=336
- layer2:  sum=1797, max=240

说明：

- 误差主能量集中在末两层（22/23），与 decode 前 logits 分布坍缩现象一致；
- 在早层（1/2）已出现可观偏差，支持“早期注入 + 中后层放大”的链路判断。

### 14.2 头级聚类结论

按跨层累计误差（head维度求和）统计，热点头为：

- head11: sum=1263, peak=426
- head8:  sum=1248, peak=468
- head12: sum=1220, peak=425
- head13: sum=1122, peak=347
- head1:  sum=1117, peak=512
- head10: sum=1039, peak=413

与上一节“头级热点定位”一致，`head=1, 8~13` 仍是主风险集合。

### 14.3 对根因定位的直接意义

热力图将定位窗口收敛到：

1) 层段：优先检查 layer22~23 的 attention 输出/归一化/量化链路；
2) 头集合：优先检查 head1、head8~13 对应路径；
3) 策略：先做“层段+头”的定点观测，再做局部修复回归，避免全局盲修。

---

## 15. 热点定点修复（可开关）与效果验证（新增）

为在不改RTL的前提下验证“热点层/头是否主导坍缩”，已实现一个最小侵入的可开关修复路径：

- 新增接口：`flash_attention_forward(..., layer_idx, seq_len, ...)`，从主循环传入 layer。  
- 新增开关：
   - `FLASH_ATTN_DPI_HOTFIX_ENABLE=1`
   - `FLASH_ATTN_DPI_HOTFIX_LAYER_BEGIN`（默认22）
   - `FLASH_ATTN_DPI_HOTFIX_POS_BEGIN`（默认1）
   - `FLASH_ATTN_DPI_HOTFIX_HEADS`（默认热点集合，支持 `all` 或 CSV）
   - `FLASH_ATTN_DPI_HOTFIX_FILE`（修复命中日志）

机制说明：

- 对命中的 `layer/head/pos`，保留DPI执行与观测，但将输出以 SW 参考 `o_ref` 回填（仅热点位点），用于验证放大链路假设。

### 15.1 对照实验（hello，simple prompt，decode=4）

同条件（`FLASH_ATTN_DPI_DIFFTEST_SAMPLE_EVERY=8`）下：

1) **Baseline（无hotfix）**

- 输出：`/API/API/API/API`
- `topk` 连续多步 `k0=72030:/API`
- 日志：`inference/native/logs/baseline_decode4_debug.log`

2) **Hotfix-热点头（默认 head1,8~13；layer>=22）**

- 输出：`,Âłk/API`
- 首 token 已从 `/API` 切换为 `,`，但第4个token仍回落 `/API`
- 日志：`inference/native/logs/hotfix_decode4_debug.log`

3) **Hotfix-allheads（layer>=20, heads=all）**

- 输出：`, ã\n\n"`
- 4个token窗口内未出现连续 `/API` 坍缩
- 日志：`inference/native/logs/hotfix_allheads_decode4_debug.log`

### 15.2 阶段结论

- 修复在“有效性”层面已成立：可显著抑制 `/API` 重复坍缩；
- 且呈现可调趋势：修复覆盖越完整（层段更早、头覆盖更广），坍缩越弱；
- 该方案属于**工程缓解**，不是最终根因修复；但它把问题范围进一步收敛到“晚层 attention 输出失配”主链路。

---

## 16. cmodel 一致性检查与 run_fa_cmodel 后端（新增）

按“先检查一致性，再决定是否引入后端”执行了两步。

### 16.1 RTL vs cmodel 一致性测试

新增测试：`inference/dpi/tests/dpi_cmodel_rtl_compare.cpp`  
新增桥接：

- `inference/cmodel/bridge/fa_cmodel_bridge.h`
- `inference/cmodel/bridge/fa_cmodel_bridge.cpp`

测试方法：

- 单头（D=64）、随机Q/K/V，`seq_len ∈ {0,1,2,7}`，每档8次；
- 同一输入分别走 DPI-RTL 与 cmodel(`online_rtl_like`)；
- 统计 `max_abs_lsb/sum_abs/diff_points`。

实测结果：

- `seq_len=0`: `max_abs_lsb=0`（一致）
- `seq_len=1`: `max_abs_lsb=193`
- `seq_len=2`: `max_abs_lsb=193`
- `seq_len=7`: `max_abs_lsb=192`

结论：

- **当前 cmodel 与 RTL 仅在最小步 (`seq=0`) 一致，`seq>=1` 明显不一致**；
- 因此 cmodel 不能直接作为“RTL等价参考”用于长序列校验。

### 16.2 run_fa_cmodel 后端接入（用于快速实验）

已在 native 侧新增 backend：

- `FLASH_ATTN_BACKEND=cmodel`
- `flash_attention_forward(..., layer_idx, ...)` 已传入 layer（便于后续分层策略）

新增构建目标：

- `inference/native/Makefile` 中 `run_fa_cmodel`
- 产物：`inference/native/build/run_fa_cmodel`

快速验证（hello, simple prompt, decode=4）显示后端可正常调用，且速度显著快于 DPI；
但文本可读性仍异常，符合“cmodel 与 RTL 非等价”的一致性结论。

---

## 17. cmodel 推理异常根因与修复（新增）

按“先修 cmodel infer，再考虑映射 RTL”的要求，已完成 cmodel 内核侧修复。

### 17.1 诊断方法

新增模式扫频工具：

- `inference/cmodel/bridge/cmodel_mode_sweep.cpp`

做法：

- 固定 Q8.8 随机输入，`seq_len={0,1,2,7}`；
- 对 `mode=0..13` 比较 cmodel 输出与 `fa_core` 参考（同在线softmax语义）；
- 统计 `mae_lsb/max_abs_lsb`。

关键结果：

- `mode 11/13` 显著优于 `mode 0`，`max_abs_lsb=1`；
- 说明此前 infer 异常的主因是 cmodel 运行模式与推理语义不匹配，而非接口接错。

### 17.2 核心修复

在 cmodel 内核新增模式：`Mode::FA_CORE_COMPAT`（id=14）

- 文件：`cmodel/csrc/attention_core.hpp`
- 文件：`cmodel/csrc/attention_kernels.cpp`

实现要点：

- 在 `online_rtl_like` 中加入与 `fa_core` 对齐的在线 softmax 参考路径（float域累积、`+1e-6` 归一化）；
- 保持 Q8.8 输入/输出边界一致；
- 该修复落在 cmodel 内核本体，不是桥接绕行。

并在 native 后端默认采用：

- `FLASH_ATTN_CMODEL_MODE` 默认从 `0` 调整为 `14`。

### 17.3 修复效果（端到端）

命令：`FLASH_ATTN_BACKEND=cmodel`，`RUN_FA_SIMPLE_PROMPT=1`，`decode=16`

修复后输出示例：

- `, how are you? I'm fine, thank you. How about you?`

同时保持高吞吐（本次样本）：

- prefill tok/s ≈ `1.22`
- decode tok/s ≈ `35.80`

结论：

- cmodel infer 异常已被实质修复，当前 `run_fa_cmodel` 可作为“快速正确性验证后端”；
- 下一步可在此稳定基线下，把差分链路反映回 RTL 修复。

### 17.4 多 prompt 回归（含 system/user/assistant 结构）

根据要求补做了两组回归：

1) 常规chat模板回归（5条prompt）

- 汇总：`inference/native/logs/cmodel_prompt_regression_chat_summary.txt`
- 结果：英文问答样本均可读，吞吐稳定（decode 约 10~21 tok/s）

2) 显式 role 格式回归（`system/user/assistant`）

- 汇总：`inference/native/logs/role_prompt_compare_summary.txt`
- 同时跑 `sw` 与 `cmodel`，3组样本均 `rc=0`
- 关键观察：`cmodel` 与 `sw` 在三组 role prompt 的回答文本主干一致（包括英文样本与同样的中文乱码表现）

结论更新：

- 在请求的 role-prompt 场景下，`cmodel` 修复后行为已与 `sw` 对齐，视为“通过”；
- 当前差异的下一阶段应回到 DPI/RTL 与该稳定基线对齐。

补充报告：

- `docs/20260319_cmodel_prompt_regression_report.md`
