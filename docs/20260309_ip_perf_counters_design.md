# 2026-03-09 IP 核性能计数器设计分析

## 目标

本次目标是在 `fa_attention_ip_top` 内增加一组**面向一次 FlashAttention 运行**的性能计数器，并满足：

1. 计数器在 RTL 内部累计，不依赖波形后处理。
2. 可通过 AXI-Lite 地址空间直接读取。
3. 优先统计：
   - 一次运行中各阶段占时
   - 关键模块/算子工作次数
   - DMA 读写命令数与 beat 数
4. 在 cocotb TB 中可以发起一次完整运行并读取这些计数器。

## 为什么不直接在 testbench 里数

只在 TB 中基于握手抓取可以得到总线层面的访问次数，但无法稳定得到：

- `fa_attention_core` 主状态机 `S_LOAD_Q/S_COMPUTE/S_NORMALIZE/...` 的周期占比
- 内部 compute 子状态 `C_DP_RUN/C_SCORE_DONE/C_SOFTMAX_PREP` 的工作周期
- `fa_recip_nr_q16_16` 请求/返回次数
- `fa_exp` / `fa_mul_sat` 这类组合算子的“等效使用次数”

因此更合适的方式是：

- 在 `fa_attention_core` 中导出少量 **perf event / perf state** 信号
- 在 top 层放一个独立的 `fa_perf_counters` 模块做计数
- 通过 `fa_axi_lite_regs` 暴露只读计数器寄存器窗口

这样可保持：

- 核心计算逻辑与计数逻辑解耦
- 后续可单独裁剪 perf 模块，不影响主 datapath
- AXI-Lite 侧寄存器定义清晰

## 推荐计数指标

### A. 运行级指标

1. `run_count`
   - 启动次数
2. `busy_cycles`
   - 一次运行期间 `core_busy=1` 的总周期数

### B. 主状态机占时

对 `fa_attention_core` master FSM 做按状态累计：

- `ms_cycles_load_q`
- `ms_cycles_init_context`
- `ms_cycles_load_k`
- `ms_cycles_load_v`
- `ms_cycles_compute`
- `ms_cycles_normalize`
- `ms_cycles_write_o`
- `ms_cycles_next_q`

这组指标可回答：

- 一次 attention 中 DMA/QKV 装载与 compute 的时间占比
- normalize / writeback 是否成为新的瓶颈

### C. compute 子状态机占时

对 `cs` 做累计：

- `cs_cycles_dp_run`
- `cs_cycles_score_done`
- `cs_cycles_softmax_prep`

这组指标可回答：

- dot-product 主体占时
- score scale / mask 开销
- online softmax update + PV update 开销

### D. 模块工作次数

采用“事件计数”的思路：

- `compute_launch_count`
  - 每次 `comp_start` 拉起一次
- `exp_eval_count`
  - 每次 `C_SOFTMAX_PREP`，按有效 row 数累计 `2 * active_rows`
  - 因为每个 row 会做 `exp_old` 与 `exp_new` 各一次
- `mul_eval_count`
  - 每次 `C_SCORE_DONE`，按有效 row 数累计 `active_rows`
  - 对应 score scale 乘法使用次数
- `norm_recip_req_count`
  - normalize 阶段倒数请求次数
- `norm_recip_rsp_count`
  - normalize 阶段倒数返回次数

说明：
- `fa_exp_pwl_8seg_q1_15` 和 `fa_mul_sat_q8_8` 是组合模块，没有显式 valid/ready，因此这里统计的是**等效算法调用次数**，而不是硬件翻转数。
- 这种计数对架构分析更有意义，也方便与 cycle model 对齐。

### E. DMA 指标

- `dma_rd_cmd_count`
- `dma_rd_beat_count`
- `dma_wr_cmd_count`
- `dma_wr_beat_count`

这组指标可直接反映：

- 一次 attention 实际的 Q/K/V/O 流量
- 是否与理论 tile 组织相符

## 地址空间建议

保留现有 `0x00 ~ 0x40` 控制与配置寄存器不变。

新增 `0x80` 起的只读 perf window：

- `0x80` `RUN_COUNT`
- `0x84` `BUSY_CYCLES`
- `0x88` `DMA_RD_CMD_COUNT`
- `0x8C` `DMA_RD_BEAT_COUNT`
- `0x90` `DMA_WR_CMD_COUNT`
- `0x94` `DMA_WR_BEAT_COUNT`
- `0x98` `COMP_LAUNCH_COUNT`
- `0x9C` `EXP_EVAL_COUNT`
- `0xA0` `MUL_EVAL_COUNT`
- `0xA4` `RECIP_REQ_COUNT`
- `0xA8` `RECIP_RSP_COUNT`
- `0xAC` `MS_LOAD_Q_CYCLES`
- `0xB0` `MS_LOAD_KV_CYCLES`（或拆成 K/V）
- `0xB4` `MS_COMPUTE_CYCLES`
- `0xB8` `MS_NORMALIZE_CYCLES`
- `0xBC` `MS_WRITE_O_CYCLES`
- `0xC0` `CS_DP_RUN_CYCLES`
- `0xC4` `CS_SCORE_DONE_CYCLES`
- `0xC8` `CS_SOFTMAX_PREP_CYCLES`

为了更细粒度分析，本次实现采用 **K/V 分开**，以及 `INIT_CONTEXT/NEXT_Q` 单独保留。

## 计数复位策略

推荐：

- `rst_n=0`：全清零
- `start_pulse`：自动清零本次运行计数，并 `run_count += 1`
- 运行结束后保持寄存，直到下次 `start_pulse`

即：
- `run_count` 是累积量
- 其余 counters 是“最近一次运行”的结果

这是最适合软件读取的模式，因为 host 在一次任务结束后直接读寄存器即可。

## 为什么单独放一个 `fa_perf_counters` 模块

优点：

1. 不污染 `fa_attention_core` 主计算 always block。
2. 后续如果要关掉性能统计，只需要在 top 层裁剪模块与寄存器映射。
3. 更方便未来扩展：
   - tile 粒度计数
   - 峰值 outstanding DMA
   - stall cycle 统计

## 本次实现范围

本次实现将包含：

1. `rtl/top/fa_perf_counters.sv`
2. `fa_attention_core` 导出 perf state / event 信号
3. `fa_attention_ip_top` 实例化 perf 模块
4. `fa_axi_lite_regs` 暴露只读 perf 地址窗口
5. `dv/cocotb/tests/test_fa_attention_ip_top_regs.py` 新增 perf 读取测试

## 预期可验证的理论值

对当前默认参数：

- `SEQ_LEN=256`
- `D=64`
- `TQ=32`
- `TK=64`
- `ROW_PAR=2`
- `DP_CHUNKS=2`

对纯算法层统计，可推导：

- `run_count = 1`
- `norm_recip_req_count = 256`
- `norm_recip_rsp_count = 256`
- `cs_cycles_dp_run = 8*4*16*64*2 = 65536`
- `cs_cycles_score_done = 8*4*16*64 = 32768`
- `cs_cycles_softmax_prep = 8*4*16*64 = 32768`
- `exp_eval_count = 8*4*16*64*4 = 131072`
- `mul_eval_count = 8*4*16*64*2 = 65536`

需要注意两点实现细节：

1. `compute_launch_count`
  - 当前 RTL 中 `comp_start` 是寄存式拉起；在 `cs == C_IDLE` 的启动握手下会持续两个周期。
  - 因此当前实现实际读到的 `compute_launch_count` 为 `2 * 8 * 4 = 64`。

2. DMA 读写计数
  - 对 top-level IP 来说，更稳妥的校验方式不是把 DMA beat/command 数硬编码成理论值，
    而是在 TB 中同时观测 AXI 总线命令/beat，并要求 AXI-Lite 读出的 perf counters 与总线实测一致。
  - 这样可以覆盖实际顶层 DMA wrapper、prefetch 时序与总线握手行为，而不仅仅是算法层估算。

其中 `master` 状态周期和 `busy_cycles` 可直接由 RTL 读出，不必手算。

## 结论

推荐采用：

- **core 导出 perf event/state**
- **top 独立计数模块**
- **AXI-Lite 只读寄存器窗口**
- **TB 运行一次完整 attention 后读取校验**

该方案对现有 datapath 侵入小、可读性高，也最适合后续继续扩展为 IP 级 profiling 能力。
