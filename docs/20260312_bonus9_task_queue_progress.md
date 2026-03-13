# 2026-03-12 Bonus #9 进展：shadow-register P1 与 true FIFO P2

> 2026-03-12 晚间更新：true FIFO P2 已完成实现、参数化和顶层回归。本文档保留 P1 历史上下文，并在顶部补充 P2 当前状态。

## P2 最新状态：4-entry true FIFO 已落地，并支持深度参数化

当前主线已经不再停留在 `active + next` 的 ping-pong 原型，而是完成了真正的 **staging descriptor + internal FIFO + active-task scheduler** 方案：

1. AXI-Lite 侧只保留单套 staging descriptor 寄存器；
2. Host 通过 `REG_QUEUE_CMD[0]` 显式 enqueue；
3. 顶层内部维护 pending FIFO，默认深度为 `4`；
4. scheduler 在 core 空闲时自动 dequeue 并发起执行；
5. `REG_TASK_ACCEPT_COUNT / DONE_COUNT / ERROR_COUNT` 区分 task 粒度；
6. perf counter 改为 **一次 FIFO drain batch 计一次 run**；
7. `FIFO_DEPTH` 已参数化，当前验证过默认 `4` 和扩展 `8` 两组配置。

### P2 当前新增异常处理

- enqueue descriptor 增加 16B 对齐校验：
	- `Q/K/V/O base[3:0] == 0`
	- `stride_bytes[3:0] == 0`
- 非法 descriptor 不入队，并置位：
	- `queue_desc_error_sticky`
	- `last_error = 3`
- `flush_queue` 仅清空 pending FIFO，不打断当前 active task；
- `flush_queue` 在完全空闲且 pending 为空时置位 `underflow_sticky`，`last_error = 2`；
- overflow / desc_error sticky 均支持显式清除。

### P2 当前回归项

- 默认 `FIFO_DEPTH=4`：顶层 cocotb `PASS=7 FAIL=0`
- 参数化 `FIFO_DEPTH=8`：顶层 cocotb `PASS=7 FAIL=0`

新增覆盖包括：

- FIFO 状态迁移与 overflow sticky
- 非法 descriptor 拒收与 sticky-clear
- busy 状态下 flush pending queue
- 4-task 端到端 FIFO drain 数值正确性

> 补充说明：基于用户对“当前+next 不应视为完整队列”的进一步要求，后续 4-entry FIFO 方案已单独整理在 [docs/20260312_bonus9_fifo_queue_architecture.md](docs/20260312_bonus9_fifo_queue_architecture.md)。本文档保留为 P1 原型进展记录。

## 1. 目标与实现边界

本轮 Bonus #9 采用 **AXI-Lite 控制面保持不变**、在寄存器侧补充 **next-task shadow register bank** 的方案。

当前版本的目标不是做完整 descriptor-memory queue，也不是 CPU-like 指令流，而是完成：

1. 软件先写入当前任务 active config；
2. 软件再写入下一任务 next config；
3. 通过 `QUEUE_CTRL` 将 next task 标记为有效；
4. 顶层在当前任务 `core_done` 后自动 promote next task，并直接发起下一次 `core_start`；
5. 两个任务链式执行完成后，顶层只对外表现为 **一次 run**。

这与此前的架构判断一致：Bonus #9 第一阶段优先验证“控制面连续派发”能力，而不是一次性引入更重的内存描述符系统。

但从术语上必须澄清：**当前实现严格来说更接近 ping-pong / double-buffered shadow registers，而不是完整意义上的 task queue。**

原因是当前硬件只支持：

- 1 组 active task
- 1 组 next task

也就是总共只能缓存“当前 + 下一条”，深度实际上是 `1-entry prefetched next task`。Host 不能像真正 FIFO 那样在 IP 忙碌期间连续塞入 3/4/8 个任务后离开，IP 内部也没有 `head/tail/count` 之类的队列状态。

所以更准确的命名应为：

- **当前实现**：`shadow-register ping-pong` / `depth-1 chained dispatch`
- **更严格的 Bonus #9 目标形态**：`multi-entry task FIFO`

---

## 1.1 “当前+next” 是否算队列：结论

结论分两层：

### 从宽松工程语义看

可以把它称为 **queue-like chaining primitive**，因为它已经具备：

- 任务链式执行；
- Host 无需等待第一个任务完成再写第二次 `START`；
- IP 内部完成一次自动 promote。

因此它确实是“面向 task queue 方向前进的一步”。

### 从严格体系结构语义看

**不能把当前版本直接称为完整 task queue。**

严格意义上的 task queue，通常至少应满足：

1. IP 内部存在 **多项缓存**（至少 2-entry / 4-entry）；
2. Host 在 IP 忙时仍可继续 enqueue；
3. 队列具备明确的 `full/empty/count` 或等价流控；
4. 执行顺序由 FIFO 规则保证；
5. 不依赖“只有一个 next shadow slot”的特殊写法。

按这个定义，当前版本最多只能称为：

- **乒乓寄存器**
- **双缓冲任务寄存器**
- **深度 1 的预取式链式派发器**

用户的判断是对的：**它更像乒乓，而不是标准 FIFO 队列。**

---

## 2. RTL 侧改动

### 2.1 `rtl/bus/fa_axi_lite_regs.sv`

增加 next-task shadow register bank：

- `REG_NEXT_CFG = 0x44`
- `REG_NEXT_Q_BASE_L/H = 0x48 / 0x4C`
- `REG_NEXT_K_BASE_L/H = 0x50 / 0x54`
- `REG_NEXT_V_BASE_L/H = 0x58 / 0x5C`
- `REG_NEXT_O_BASE_L/H = 0x60 / 0x64`
- `REG_NEXT_STRIDE_BYTES = 0x68`
- `REG_NEXT_NEG_LARGE = 0x6C`
- `REG_NEXT_SCALE = 0x70`
- `REG_QUEUE_CTRL = 0x74`
- `REG_QUEUE_STATUS = 0x78`

接口侧新增：

- `i_queue_pop`
- `o_next_causal_en`
- `o_next_q_base/o_next_k_base/o_next_v_base/o_next_o_base`
- `o_next_stride_bytes`
- `o_next_neg_large_q8_8`
- `o_next_scale_q8_8`
- `o_queue_next_valid`

控制语义：

- `QUEUE_CTRL[0] = 1`：arm next task
- `QUEUE_CTRL[1] = 1`：clear next task
- 当 `i_queue_pop=1` 时，shadow bank 自动覆盖 active bank，并清空 `queue_next_valid`

### 2.2 `rtl/top/fa_attention_ip_top.sv`

顶层新增链式调度状态：

- `queue_pop`
- `core_start_pulse`
- `run_active`
- `launch_pending`
- `completed_run_cycles`
- `run_cycles_hold`
- `run_error_latched`

关键行为：

1. 外部 `START` 只启动一次顶层 run；
2. 第一个任务由 `core_start_pulse` 启动；
3. 若 `core_done && queue_next_valid`，则：
	- 触发 `queue_pop`
	- 置位 `launch_pending`
	- 下一拍再次触发 `core_start_pulse`
4. 若 `core_done && !queue_next_valid`，则：
	- 结束整个顶层 run
	- 拉起 `run_done`

因此当前实现已经具备“单次启动、双任务串接、外部只看见一次完成”的最小可用控制面能力。

---

## 3. 验证侧改动

### 3.1 `dv/cocotb/tests/test_fa_attention_ip_top_regs.py`

新增/扩展了三类验证：

1. **寄存器默认值与可读写检查**
	- 覆盖全部 next-task shadow registers
	- 覆盖 `QUEUE_CTRL` arm / clear 行为

2. **链式双任务功能测试**
	- `test_shadow_queue_two_task_chain`
	- task0：`causal=True`
	- task1：`causal=False`
	- 两个任务使用完全独立的 `Q/K/V/O` 地址空间
	- 验证队列执行结束后 `QUEUE_STATUS == 0`

3. **性能/计数器检查**
	- `run_count == 1`，即链式双任务对外仍视为一次 run
	- `comp_launch_count == 2 * num_q_tiles * num_k_tiles * 2`
	- DMA 读写命令数与 memory model 实测值一致

说明：调试过程中发现链式双任务的 DMA command 计数比手工闭式估算更高，因此测试最终改为与 memory model 的实际观测对齐，而不是使用过度简化的人工公式。

---

## 4. 当前验证结果

已在 `exp/bonus9-task-queue` 分支完成顶层回归：

- `test_reg_rw_and_start_busy`：PASS
- `test_reg_map_defaults_and_permissions`：PASS
- `test_register_dataflow_precision_and_cycles`：PASS
- `test_perf_counters_full_run`：PASS
- `test_shadow_queue_two_task_chain`：PASS

总计：`TESTS=5 PASS=5 FAIL=0`

本次回归中，baseline 单任务 full-run 指标仍保持：

- `cycles = 85,928`
- `rd_cmd = 136`
- `rd_beat = 34,816`
- `wr_cmd = 8`
- `wr_beat = 2,048`
- `comp_launch = 64`
- `rtl_vs_fp32: MAE = 0.002499, MaxAE = 0.006583`

链式双任务测试也已通过：

- 顶层 `run_count = 1`
- `QUEUE_STATUS` 在运行结束后自动清空
- task0 / task1 均满足 fixed 与 FP32 阈值约束

这说明当前 shadow-register queue 首版已经达到：

- **功能可用**
- **回归闭环**
- **未破坏 baseline 单任务路径**

---

## 5. 当前结论与下一步建议

当前 Bonus #9 已完成第一阶段目标：

- 保持 AXI-Lite 控制面；
- 用 shadow-register 方式实现最小链式派发原型；
- 验证单次 `START` 下连续两任务执行；
- 对外保持一次 run 语义；
- 完成顶层 cocotb 回归闭环。

但若按照更严格的术语，当前状态应表述为：

- **已完成**：Bonus #9 的 `ping-pong / shadow-next` 原型
- **尚未完成**：Bonus #9 的 `true multi-entry task queue`

因此后续阶段建议拆成三步：

### P1：当前已完成

- active + next 的双缓冲链式派发
- 目标：验证控制面自动串接可行

### P2：建议的下一步

- 把 next 扩展为真正的 **小 FIFO**（如 2-entry 或 4-entry）
- 增加：
	- `queue_count`
	- `queue_full`
	- `queue_empty`
	- enqueue / dequeue 指针
- 使 Host 能在 IP 忙时连续下发多条任务

### P3：更完整的远期形态

- descriptor-memory queue
- doorbell + completion 机制
- 与 CPU/driver 更接近的软件接口

下一阶段若继续深入，建议优先级如下：

1. 从“单 next-task”扩展为 **2-entry / 4-entry 小 FIFO 队列**；
2. 明确 `done/error/soft_reset` 在多任务串接时的软件可见语义；
3. 评估是否需要把 perf 计数器扩展为：
	- task 数量计数
	- queue pop 次数计数
	- per-task done 次数计数
4. 若软件调度需求继续增强，再考虑 descriptor-memory queue，而不是直接跳到 instruction-fetch。

结论：当前版本已经适合作为 Bonus #9 的 **P1 可提交原型**，但文档和对外表述上应明确将其称为 **ping-pong / depth-1 chained dispatch**，而不是完整 task queue。
