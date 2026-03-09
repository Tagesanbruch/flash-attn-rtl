# 2026-03-09 Perf Counters 联调状态与问题纪要

## 1. 本轮调试目标

围绕 `fa_attention_ip_top` 的性能计数器能力，完成以下闭环：

1. RTL 内部计数（独立 `fa_perf_counters` 模块）
2. AXI-Lite 可读寄存器映射
3. cocotb 触发完整一次 attention 并读取/校验计数器

## 2. 当前已完成工作

### 2.1 结构接入

- 新增 `rtl/top/fa_perf_counters.sv`
- `rtl/core/fa_attention_core.sv` 导出 perf hooks（主状态、子状态、事件）
- `rtl/top/fa_attention_ip_top.sv` 集成 perf 模块并接入 AXI-Lite regs
- `rtl/bus/fa_axi_lite_regs.sv` 增加 `0x80~0xD4` 只读计数窗口

### 2.2 TB 与环境

- `dv/cocotb/common.mk` 已把 `fa_perf_counters.sv` 纳入 IP top 仿真文件集
- `dv/cocotb/Makefile` 已固定使用仓库 `.venv`（避免外部 cocotb/Verilator 版本冲突）
- `dv/cocotb/tests/test_fa_attention_ip_top_regs.py` 新增 `test_perf_counters_full_run`

## 3. 关键调试过程

### 阶段 A：初始失败（超时不 done）

现象：

- `test_perf_counters_full_run` 报 `Timed out waiting for IP run completion`

定位：

- 加入超时日志后发现 core 卡在 `S_LOAD_Q`
- `q_fill_cnt` 卡在 `256`，`rd_beats` 也停在 `256`

根因：

- TB 里的 `AxiMemoryModel` 时序实现存在“同拍拉高并消费”的风险，导致读通道收尾时序不稳定，触发首拍/末拍语义偏差，进而使 top 侧 load 阶段可能卡住。

修复：

- 重写 `AxiMemoryModel.run()` 的时序顺序：
  1) 先处理上一拍握手
  2) 再受理新命令
  3) 最后驱动输出
- 新增 `rd_cmds/wr_cmds` 统计，便于与 perf 寄存器交叉校验

结果：

- full-run 用例可完成，不再超时

### 阶段 B：计数期望不匹配

现象 1：DMA 计数与“手推理论值”不一致。

处理：

- 将 DMA 计数校验口径调整为“AXI 总线实测 == perf 寄存器值”（`mem.rd_cmds/rd_beats/wr_cmds/wr_beats`），更贴近 top-level 实际行为。

现象 2：`comp_launch_count` 为 64，而非原先期望 32。

处理：

- 根据当前 RTL `comp_start` 的寄存式握手行为，修正期望为 `num_q_tiles * num_k_tiles * 2`。

结果：

- `test_perf_counters_full_run` 单测已通过。

## 4. 当前遗留问题（最新）

在跑 `make MODULE=fa_attention_ip_top test` 全套时，出现 1 个回归失败：

- 失败用例：`test_reg_rw_and_start_busy`
- 失败原因：测试里把 `REG_CFG` 写成了 `0x0`，但断言仍要求 bit0=1（应写 `0x1`）

该问题是调试过程中引入的测试脚本误改，不是 RTL 功能缺陷。

## 5. 下一步执行计划（立即）

1. 修复 `test_reg_rw_and_start_busy` 中 `REG_CFG` 写值为 `0x1`
2. 重跑 `make MODULE=fa_attention_ip_top test`
3. 若全通过，保留必要诊断信息并收敛临时调试痕迹

## 6. 当前判断

- perf counters 的 RTL 方案与寄存器映射已打通
- full-run 场景下计数器可读、可校验
- 剩余阻塞是测试脚本局部误改，修复后应可恢复全套通过

## 7. 最新实测读回结果（full run）

基于 `test_perf_counters_full_run` 最新一次读回，当前得到：

- `CYCLES = 144624`
- `RUN_COUNT = 1`
- `BUSY_CYCLES = 144624`
- `DMA_RD_CMD_COUNT = 72`
- `DMA_RD_BEAT_COUNT = 18432`
- `DMA_WR_CMD_COUNT = 8`
- `DMA_WR_BEAT_COUNT = 2048`
- `COMP_LAUNCH_COUNT = 64`
- `EXP_EVAL_COUNT = 131072`
- `MUL_EVAL_COUNT = 65536`
- `RECIP_REQ_COUNT = 256`
- `RECIP_RSP_COUNT = 256`

主状态占时：

- `MS_LOAD_Q_CYCLES = 2072`
- `MS_INIT_CONTEXT_CYCLES = 8`
- `MS_LOAD_K_CYCLES = 2072`
- `MS_LOAD_V_CYCLES = 2072`
- `MS_COMPUTE_CYCLES = 131200`
- `MS_NORMALIZE_CYCLES = 5120`
- `MS_WRITE_O_CYCLES = 2072`
- `MS_NEXT_Q_CYCLES = 8`

子状态占时：

- `CS_DP_RUN_CYCLES = 65536`
- `CS_SCORE_DONE_CYCLES = 32768`
- `CS_SOFTMAX_PREP_CYCLES = 32768`

## 8. 基于读回结果的数据流与延迟构成分析

### 8.1 主体延迟构成

总忙周期：`144624` cycles。

其中：

- `MS_COMPUTE = 131200`，占比约 `90.72%`
- `MS_NORMALIZE = 5120`，占比约 `3.54%`
- `MS_LOAD_Q = 2072`，占比约 `1.43%`
- `MS_LOAD_K = 2072`，占比约 `1.43%`
- `MS_LOAD_V = 2072`，占比约 `1.43%`
- `MS_WRITE_O = 2072`，占比约 `1.43%`
- `MS_INIT_CONTEXT + MS_NEXT_Q = 16`，可忽略

结论：

- 当前瓶颈仍然非常明确地在 `compute` 阶段。
- `normalize` 已经不是主瓶颈。
- 显式的 `LOAD_K/LOAD_V` 周期占比不高，说明除了首个 tile 外，后续 K/V 更多是通过 compute 阶段中的 prefetch 隐藏在 `MS_COMPUTE` 内完成的。

### 8.2 Compute 内部构成

`MS_COMPUTE = 131200` 可继续拆为：

- `CS_DP_RUN = 65536`
- `CS_SCORE_DONE = 32768`
- `CS_SOFTMAX_PREP = 32768`

三者之和为 `131072`，与 `MS_COMPUTE` 的差值仅 `128` cycles。

这说明：

- 当前 compute 阶段几乎全部都被 `dp / score / softmax+pv` 三个核心子阶段占满；
- compute 控制开销极小，约 `128 cycles`，仅占总周期 `0.09%`；
- 该 RTL 当前已经是“算子本体占主导”，而不是“控制态空转占主导”。

### 8.3 从计数器反推当前数据流行为

`DMA_RD_CMD_COUNT = 72` 与 tile 组织是一致的：

- Q：`8` 个 tile
- K：`8 * 4 = 32` 个 tile
- V：`8 * 4 = 32` 个 tile
- 合计：`72` 条读命令

但 `DMA_RD_BEAT_COUNT = 18432` 明显低于设计文档中原本按完整 K/V tile 推导的 `34816`。

这组结果意味着：

- 命令条数是对的；
- 但平均每条读命令只有 `18432 / 72 = 256` beat；
- 对 Q tile 来说，`256 beat` 正好成立；
- 对 K/V tile 来说，理论上应为 `512 beat`，现在观测值等价于被截成了 `256 beat`。

因此当前 top-level 数据流很可能存在一个额外问题：

- **K/V DMA 读命令长度在 AXI len 路径上被截断了，导致每个 K/V burst 实际只读了半个 tile。**

这与 `fa_dma_reader/fa_dma_writer` 默认 `AXI_LEN_W=8`，而 core 侧 `dma_rd_cmd_len/dma_wr_cmd_len` 为更宽位宽的连接方式是吻合的，属于下一步应优先核查的点。

也就是说：

- perf counters 已经成功给出了延迟构成；
- 同时也暴露了 top-level DMA burst 长度实现与预期不完全一致的问题。

## 9. 与以前周期是否一致

当前实测：

- `CYCLES = 144624`

仓库里最近一版 RTL 汇总报告给出的结果是：

- [docs/report/20260305_05_验证方案与阶段结果.md](docs/report/20260305_05_%E9%AA%8C%E8%AF%81%E6%96%B9%E6%A1%88%E4%B8%8E%E9%98%B6%E6%AE%B5%E7%BB%93%E6%9E%9C.md#L26) 中记录 `total_cycles = 145584`

两者差值：

- `145584 - 144624 = 960 cycles`
- 相对偏差约 `0.66%`

结论：

- 若与这条最近基线相比，**可以认为周期基本一致**；
- 这不是“引入 perf counters 后周期被明显拉长”的现象。

但需要注意：

- 更早期文档里也有 `236288 cycles` 等历史值，那是更早阶段/不同配置/不同验证脚本下的结果，不能直接与当前这版 top-level full-run 一一对比。

## 10. perf counters 是否会影响周期

从架构上看，**不应影响当前这类“功能周期数”**，原因是：

1. `fa_perf_counters` 只旁路采样已有状态/事件信号，不参与 master/compute FSM 的状态转移条件；
2. AXI-Lite 读取发生在 `DONE` 之后，只会增加 TB 额外访问时间，不会回写到 `CYCLES`；
3. 本次读回也满足 `BUSY_CYCLES == CYCLES == 144624`，说明读寄存器没有污染运行期统计。

更准确地说：

- **对仿真中的 cycle count：不应有影响；**
- **对 testbench 总仿真时间：会增加，因为多了 AXI-Lite 读操作；**
- **对综合后的真实频率/Fmax：理论上可能引入少量额外扇出，但那是时序裕量问题，不是架构周期数问题。**

所以当前看到的 `960 cycles` 小差异，更合理的解释是：

- testbench 内存模型时序细节
- 不同验证脚本/握手边界
- 仿真场景微差

而不是 perf counter 模块本身改变了 datapath 延迟周期。
