# 2026-03-12 Bonus #9 架构设计：从 baseline depth-1 到 4-entry task FIFO

> 实现更新：本文档中的 4-entry FIFO 方案已完成 RTL 落地，并进一步补充了 `FIFO_DEPTH` 参数化、descriptor 对齐校验，以及 busy-flush / desc-error / overflow 的 cocotb 覆盖。默认验证配置为 `FIFO_DEPTH=4`，并额外完成 `FIFO_DEPTH=8` 回归。

## 0. 实现状态补充

当前实现已经对应到本文档的主架构：

- `rtl/bus/fa_axi_lite_regs.sv`
   - staging descriptor + queue cmd/status/capacity/task-counter register map
- `rtl/top/fa_attention_ip_top.sv`
   - internal FIFO
   - active-task register bank
   - auto scheduler
   - batch-level perf start
- `dv/cocotb/tests/test_fa_attention_ip_top_regs.py`
   - 状态迁移测试
   - 4-task 行为测试
   - 非法 descriptor / busy flush 异常测试

### 0.1 当前补充约束

首版参数化实现支持：

- `1 <= FIFO_DEPTH <= 15`
- queue status 仍使用 4-bit `count/free_slots` 位域
- 已验证的深度点：`4`、`8`

### 0.2 当前 descriptor 校验策略

enqueue 时采用以下合法性检查：

1. `stride_bytes != 0`
2. `scale_q8_8 != 0`
3. `Q/K/V/O base` 均满足 16B 对齐
4. `stride_bytes` 满足 16B 对齐

不满足时：

- 本次 enqueue 被拒绝
- `queue_desc_error_sticky=1`
- `last_error=3`

### 0.3 当前补充异常语义

- `flush_queue`
   - 若存在 pending FIFO：清空 pending，不打断 active task
   - 若系统完全空闲且 pending 为空：置位 `queue_underflow_sticky=1`，`last_error=2`
- `queue_overflow_sticky / queue_underflow_sticky / queue_desc_error_sticky`
   - 分别通过 `QUEUE_CMD[1] / [2] / [3]` 清除
- cocotb 构建可直接使用：
   - `make test MODULE=fa_attention_ip_top PARAM_FIFO_DEPTH=8`

## 1. 设计目标与核心判断

### 1.1 目标重述

本轮 Bonus #9 不再沿用 `current + next` 的双寄存器思路，而是把 **baseline 的单任务配置接口本身视为“深度为 1 的任务注入路径”**，然后在 IP 内部扩展成 **4-entry task FIFO**。

也就是说：

- Host 仍然通过一组“任务描述寄存器”写入任务参数；
- 但这组寄存器不再表示“当前 active task”；
- 而是表示 **enqueue staging area / task descriptor write port**；
- 当 Host 通过显式握手触发 `enqueue` 时，该组寄存器被编码并写入内部 FIFO；
- 后端 scheduler 只要看到 FIFO 非空，就自动取出任务并驱动 `fa_attention_core` 执行。

因此更准确的结构是：

$$
\text{Host AXI-Lite writes} \rightarrow \text{Descriptor Staging Regs} \rightarrow \text{Pack/Enqueue} \rightarrow \text{Task FIFO} \rightarrow \text{Scheduler} \rightarrow \text{Core}
$$

### 1.2 关键设计原则

1. **不引入两倍 Q/K/V/O 接口**
   - 删除 `NEXT_*` 这一整套影子寄存器概念；
   - 保留单套 baseline 风格的任务描述寄存器作为 enqueue 端口。

2. **把任务提交与任务执行解耦**
   - Host 写的是“待入队任务”；
   - Core 执行的是“已出队 active task”；
   - 两者之间由 FIFO 解耦。

3. **Host 明确感知 FIFO 状态**
   - 需要明确 `ready/full/empty/count/error` 等语义；
   - Host 可以在连续发 4 个任务时知道是否还能继续发。

4. **握手逐次进行即可**
   - 本题任务粒度很大，寄存器握手不是瓶颈；
   - 没有必要为了 enqueue 控制面专门做 AXI-Stream 式突发数据通道；
   - 但控制语义应尽量参考 `valid/ready`。

5. **调度器自动消费 FIFO**
   - 只要 FIFO 非空且 core 空闲，就自动出队并启动；
   - Host 不需要每个任务都重新写 `START`。

---

## 2. 新的数据流定义

## 2.1 总体数据流

建议采用如下数据流：

```text
AXI-Lite Host
   |
   | 写 baseline 风格任务描述寄存器
   v
[Task Descriptor Staging Registers]
   |
   | enqueue_valid / enqueue_ready
   v
[Pack/Encode]
   |
   v
[4-entry Task FIFO]
   |
   | dequeue when core idle
   v
[Active Task Registers]
   |
   v
[fa_attention_core]
```

### 2.2 baseline 在新语义下的位置

原 baseline：
- Host 写一组 `Q/K/V/O/CFG/SCALE/...`
- Host 写 `CTRL.START`
- 顶层直接驱动 core

新 Bonus #9：
- Host 写一组 `Q/K/V/O/CFG/SCALE/...`
- Host 写 `QUEUE_CMD.ENQUEUE`
- 若 `QUEUE_READY=1`，则任务被 pack 后写入 FIFO
- FIFO 非空时 scheduler 自动拉起 core

因此 baseline 相当于：
- 原先的“直接执行路径”
- 被重解释成“深度 1、无缓存的任务注入路径”

---

## 3. 控制面接口设计

## 3.1 不建议继续暴露 `START` 为主入口

如果仍保留 “Host 先写描述，再写 `START`” 的语义，会出现混乱：

- `START` 到底是“开始执行当前描述”？
- 还是“把当前描述写入 FIFO”？
- 如果 FIFO 非空时再次写 `START`，语义是否等于 enqueue？

因此建议：

### 推荐语义

- `CTRL.START`：仅用于 legacy 模式或保留兼容，不作为 Bonus #9 主提交流程
- `QUEUE_CMD.ENQUEUE`：唯一标准的任务提交动作
- scheduler 自动从 FIFO 拉任务，不需要 Host 对每个任务单独 `START`

### 更激进但更干净的语义

也可以直接把：

- `CTRL.START` 重定义为 `ENQUEUE`

但这会影响 baseline 软件路径和旧测试，因此**更推荐保留兼容位，同时新增队列命令寄存器**。

---

## 3.2 Host 如何感知 FIFO 状态

用户提出的问题是本设计最关键的一部分。建议使用 **一个 32-bit 状态寄存器 + 一个 32-bit 命令寄存器**，而不是把所有状态压成模糊编码。

原因：

1. AXI-Lite 本来就是 32-bit 粒度；
2. 额外占用 4B 状态寄存器的成本极低；
3. 软件可读性和验证便利性远高于压缩编码；
4. 后续想预留 `error/overflow/qos/reserved` 位时更容易扩展。

### 推荐寄存器

#### `REG_QUEUE_STATUS`（32-bit）

建议位定义：

- `[0] queue_empty`
- `[1] queue_full`
- `[2] queue_ready_for_enqueue`
- `[3] queue_busy_exec`：当前 core 是否有 active task 正在执行
- `[7:4] queue_count`：当前 FIFO 中有效条目数，支持到 15，足够覆盖 4-entry
- `[11:8] queue_free_slots`
- `[12] queue_overflow_sticky`
- `[13] queue_underflow_sticky`
- `[14] queue_desc_error_sticky`
- `[15] scheduler_active`
- `[23:16] reserved`
- `[31:24] optional last_error_code`

这样 Host 可以同时知道：

- 还能不能继续提交
- 还能提交几个
- 当前是否正在执行
- 之前是否出现过异常

#### `REG_QUEUE_CMD`（32-bit）

建议位定义：

- `[0] enqueue_req`：将当前 staging descriptor 入队
- `[1] clear_overflow_sticky`
- `[2] clear_underflow_sticky`
- `[3] clear_desc_error_sticky`
- `[4] flush_queue`：清空 pending FIFO，不打断 active task 或按模式可选
- `[5] abort_active_and_flush`：强制停止 active task 并清空全部队列
- `[7:6] reserved`
- `[15:8] optional qos_class`
- `[31:16] reserved`

### 为什么不用“只有一个 status 编码”

例如用一个枚举：

- `0=idle`
- `1=ready`
- `2=full`
- `3=error`

这种编码的缺点是：

- 无法同时表达 `busy but still enqueue-able`
- 无法表达 “队列非空但未满”
- 无法表达剩余空位数
- 对 Host 连续发 4 个任务非常不友好

因此 **位域 + count/free_slots** 是更合理的方案。

---

## 3.3 是否需要 valid/ready 风格接口

结论：**需要，但不必完全做成 AXI-Stream 引脚协议。**

在 AXI-Lite 控制面上，建议软件语义模拟 `valid/ready`：

- Host 先读 `QUEUE_STATUS.queue_ready_for_enqueue`
- 若为 1，则写 staging regs
- 然后写 `QUEUE_CMD.enqueue_req=1`
- 若当拍 FIFO 可接收，则 enqueue 成功
- 若不可接收，则：
  - 忽略本次请求并置 `overflow_sticky`，或
  - 返回 SLVERR（不推荐先做）

### 硬件内部可定义的握手

内部建议显式建模：

- `task_push_valid`
- `task_push_ready`
- `task_push_data`
- `task_pop_valid`
- `task_pop_ready`
- `task_pop_data`

这样 RTL 结构清晰，也更接近将来扩展成真正 stream/descriptor 版本。

---

## 3.4 是否要预留 QoS / priority

结论：**建议预留，不建议首版实现仲裁行为。**

因为当前是单执行通路 FIFO：

- 即使加入 QoS，也没有多路消费端可选；
- 真正的优先级调度通常需要多队列或重排序，会破坏严格 FIFO 语义；
- 当前阶段的重点是“可靠入队+自动顺序执行”。

但可以在 descriptor 中预留：

- `qos[3:0]`
- `task_type[3:0]`
- `flags[7:0]`

后续可用于：

- 统计分类
- 软件 hint
- 将来多队列调度

---

## 4. FIFO 描述符设计

## 4.1 需要进入 FIFO 的字段

根据当前 baseline 配置，最小任务描述符建议包含：

1. `cfg.causal_en`
2. `q_base`
3. `k_base`
4. `v_base`
5. `o_base`
6. `stride_bytes`
7. `neg_large_q8_8`
8. `scale_q8_8`
9. `optional flags/qos/tag`

如果地址宽仍按当前顶层实际使用的 32-bit 地址，则推荐 payload 如下：

- `q_base[31:0]`
- `k_base[31:0]`
- `v_base[31:0]`
- `o_base[31:0]`
- `stride_bytes[31:0]`
- `neg_large_q8_8[15:0]`
- `scale_q8_8[15:0]`
- `causal_en[0]`
- `qos[3:0]`（预留）
- `task_tag[7:0]`（预留）
- `flags[7:0]`（预留）

合计大约：

$$
4 \times 32 + 32 + 16 + 16 + 1 + 4 + 8 + 8 = 213 \text{ bits}
$$

可对齐到 **224 bits** 或 **256 bits**。

### 推荐

- **首版 FIFO 宽度：256 bits**

理由：

- 编码简单；
- 对齐自然；
- 预留空间充足；
- 后续加 tag/qos/error mode 不用立刻改 FIFO 宽度。

---

## 4.2 编码 / 译码单元建议

用户提出“其实位拼接就差不多了”，这个判断基本正确。

建议结构：

### `task_desc_pack`

输入：
- staging regs 各字段

输出：
- `task_push_data[255:0]`
- `desc_valid_check_ok`

### `task_desc_unpack`

输入：
- `task_pop_data[255:0]`

输出：
- active task 各字段

### 为什么仍然建议独立 pack/unpack 模块

虽然本质是拼位，但独立模块有价值：

1. 便于统一位定义，避免各处 hardcode bit slicing；
2. 便于加入描述符合法性检查；
3. 将来若改成 descriptor-memory queue，可复用定义；
4. cocotb 可单独验证 pack/unpack 一致性。

---

## 4.3 描述符合法性检查建议

可在 `enqueue` 前做轻量检查：

- `stride_bytes != 0`
- `q_base/k_base/v_base/o_base` 对齐合法
- `scale_q8_8 != 0`（若认为 0 非法）
- 保留位是否必须为 0

若失败：

- 不入队
- 置 `desc_error_sticky`
- 可写 `last_error_code`

这样后续软件会更清楚是“队列满”还是“描述符非法”。

---

## 5. FIFO 微架构设计

## 5.1 4-entry FIFO 组织

建议使用：

- `fifo_mem[0:3]` each 256 bits
- `wr_ptr[1:0]`
- `rd_ptr[1:0]`
- `count[2:0]`

标准语义：

- push when `push_valid && push_ready`
- pop when `pop_valid && pop_ready`
- `push_ready = (count != 4)`
- `pop_valid = (count != 0)`

### 同拍 push + pop

需要支持同拍 push/pop，以避免 scheduler 在任务切换边界产生不必要空泡。

更新规则建议清晰定义：

- only push: `count+1`
- only pop: `count-1`
- both: `count保持`

---

## 5.2 Active Task 是否还需要单独寄存器

结论：**需要。**

原因：

- core 执行期很长；
- FIFO pop 只发生在任务开始前一拍；
- 出队后任务配置必须稳定保存整个执行周期。

因此建议：

- FIFO 负责 pending tasks
- `active_task_regs` 保存当前执行任务

这也是调度器与 FIFO 解耦的标准做法。

---

## 6. Scheduler / 状态机变化

## 6.1 当前状态机的问题

当前 ping-pong 原型的顶层状态，核心逻辑是：

- `start_pulse`
- `launch_pending`
- `queue_pop`
- `run_active`

它隐含假设：

- 一次 run 最多只有“当前 + 下一条”
- 是否继续执行只看 `queue_next_valid`

引入 FIFO 后，这种逻辑必须改写为：

- 是否继续执行看 `fifo_nonempty`
- Host 提交动作不再耦合到 `run_active`
- enqueue 和 execute 两条路径并行存在

---

## 6.2 推荐的顶层调度状态

建议抽象成以下状态/标志，而不必做过大的 FSM：

### 队列侧

- `fifo_count`
- `fifo_push_ready`
- `fifo_pop_valid`

### 执行侧

- `active_valid`
- `core_busy`
- `core_done`
- `core_error`
- `scheduler_issue_next`

### 运行定义

- `run_busy` 不再表示“本次 START 还没结束”
- 而应表示：

$$
run\_busy = active\_valid \;||\; core\_busy \;||\; (fifo\_count != 0)
$$

也就是“系统还有待处理或正在处理的任务”。

---

## 6.3 推荐调度流程

1. Host enqueue 若干任务进 FIFO；
2. 若 `!active_valid && !core_busy && fifo_pop_valid`：
   - pop FIFO
   - load `active_task_regs`
   - 发 `core_start_pulse`
   - `active_valid <= 1`
3. core 执行期间：
   - FIFO 仍可继续接收 Host enqueue
4. `core_done`：
   - 更新统计
   - `active_valid <= 0`
   - 若 FIFO 仍非空，下一拍继续 issue
5. 当 `active_valid=0 && core_busy=0 && fifo_count=0`：
   - 系统空闲

这才是真正“多任务连续执行”的标准模型。

---

## 6.4 DONE 语义如何定义

用户指出：

> 为什么会是外部只看见一次完成？host 不是应该意识到要发多次任务吗？

这个问题非常关键。引入 FIFO 后，**不建议再把多个任务合并成一次 opaque run_done**。

### 推荐语义

区分两类完成：

#### A. `task_done_event`

- 每完成 1 个任务，内部记一次；
- 可映射为计数器 `perf_task_done_count`
- 也可选配 sticky 中断位

#### B. `queue_idle_done`

- 当系统从非空转为空时，表示整个队列 drain 完成
- 这是“批次完成”语义，不是单任务完成语义

### 为什么比“只看见一次 done”更合理

因为 Host 确实是在主动提交多个任务：

- 它知道自己发了 4 个任务；
- 因此应该能观测每个任务完成的进度，或至少观测已完成计数；
- 如果只给一个最终 done，会丢失中间可见性。

### 建议的折中方案

保留：

- `STATUS.done_sticky`：表示“队列已 drain 完成一次”

新增：

- `REG_TASK_DONE_COUNT`
- `REG_TASK_ACCEPT_COUNT`
- `REG_TASK_ERROR_COUNT`

这样：

- baseline 软件仍可看最终 done；
- 更复杂软件可看任务级进度。

---

## 7. Host 提交流程建议

## 7.1 推荐流程：逐次 ready-valid 风格提交

建议不做 burst 提交协议，直接采用以下软件流程：

1. 轮询 `QUEUE_STATUS.queue_ready_for_enqueue`
2. 若可入队：
   - 写 staging regs
   - 写 `QUEUE_CMD.enqueue_req=1`
3. 继续下一任务

这样对 Host 来说就是：

```text
for each task:
    wait until queue_ready
    write descriptor regs
    write enqueue
```

### 为什么这足够

- 每个 attention 任务执行时间远大于几次 AXI-Lite 写寄存器的时间；
- 控制面逐次握手不会成为瓶颈；
- 验证更简单；
- 将来再升为 stream/burst 也不晚。

---

## 7.2 是否需要“连续发 4 个”的空位评估接口

需要。

因此 `QUEUE_STATUS.queue_free_slots` 很重要。

Host 可采用两种策略：

### 保守策略

- 每次提交前只检查 `ready`

### 批量策略

- 先读 `free_slots`
- 若 `free_slots >= 4`，再连续提交 4 个

第二种更符合用户提出的“host 希望连续发 4 个 attn 任务时进行评估”的需求。

---

## 8. 数据复用性：引入 FIFO 后能否挖掘

用户明确要求：先分析，不必首版实现。

结论：**可以分析，但不应把它和 FIFO 首版耦合实现。**

## 8.1 可考虑的复用方向

### 方向 A：相邻任务的 `K/V` 相同

例如多 head 或分块场景下，可能存在：

- Q 改变
- K/V 不变或部分重叠

可考虑在 scheduler 层面比较：

- `k_base`
- `v_base`
- `stride`
- `cfg`

若一致，则未来可引入：

- K/V tile cache
- active task 间的 warm reuse hint

### 方向 B：同一 batch 内地址连续

如果 FIFO 中连续任务的 `Q/O` 地址按固定 stride 递增，可考虑：

- 未来将多个 descriptor 合并成“批描述符”
- 减少 Host 控制写次数

### 方向 C：按 task_type / qos 分类

若后续加 `task_type`，可以让 scheduler 识别：

- 普通 attn
- causal attn
- 同 K/V group 的任务

但这会把简单 FIFO 变成更复杂的 reorder/cluster scheduler。

## 8.2 当前阶段建议

- **当前不实现数据复用优化**
- 只在 descriptor 中预留：
  - `task_tag`
  - `qos`
  - `flags`
- 在文档中标记未来可基于 `K/V` 相等性做复用优化

这样不会影响首版 FIFO 的闭环。

---

## 9. 验证与测试方案设计

## 9.1 测试目标分层

建议把验证拆成 4 层：

### L0：FIFO 单元级

验证：

- push/pop/count/head/tail
- full/empty
- 同拍 push+pop
- overflow/underflow sticky

### L1：pack/unpack 单元级

验证：

- staging regs -> packed descriptor -> unpacked fields 一致
- 保留位/非法描述符检测

### L2：顶层控制面级

验证：

- Host 连续 enqueue 4 个任务
- `QUEUE_STATUS` 的 `count/free_slots/full/ready` 变化正确
- FIFO 满时第 5 个任务被拒绝或报 sticky

### L3：端到端功能级

验证：

- 4 个任务按 FIFO 顺序执行
- 输出分别写回各自 O 地址
- 每个任务数值正确
- `task_done_count == 4`
- 最终 `queue_idle_done` 拉起

---

## 9.2 cocotb 下 Host 应如何建模

用户的判断是对的：

> host 应该意识到要发多次任务，然后尝试连续发 4 个

因此新测试不应再沿用“写一次 START，外部只看见一次 opaque run”的风格作为唯一主路径。

### 推荐 cocotb 行为模型

1. 生成 4 组独立任务描述符；
2. cocotb 作为 Host：
   - 轮询 `queue_ready`
   - 逐个写 staging regs
   - 逐个写 `enqueue_req`
3. 提交后：
   - 观察 `queue_count` 增加
   - core 自动开始执行
4. 执行过程中：
   - 可继续 enqueue，验证 backpressure
5. 最终检查：
   - 4 个输出都正确
   - 顺序正确
   - 计数器正确

### 是否做“burst 式多任务注入”

不建议首版实现。

原因：

- AXI-Lite 天然不适合高效大吞吐 burst descriptor 提交；
- 当前控制面瓶颈极小；
- 验证复杂度会显著提高。

---

## 9.3 建议新增的 cocotb 测试

1. `test_task_fifo_status_transitions`
   - 验证 empty -> partial -> full -> partial -> empty

2. `test_task_fifo_four_task_chain`
   - Host 连续提交 4 个任务
   - 验证顺序执行与输出正确

3. `test_task_fifo_overflow_sticky`
   - FIFO 满后继续提交第 5 个任务
   - 验证不入队且 sticky 置位

4. `test_task_fifo_enqueue_while_busy`
   - 第 1 个任务运行期间继续提交第 2/3/4 个
   - 验证并行提交路径正确

5. `test_task_fifo_task_done_and_idle_done`
   - 验证任务级计数和队列排空完成语义

---

## 10. 寄存器映射建议

以下给出一版建议映射，重点是复用 baseline 单套描述寄存器，删除 `NEXT_*`：

- `0x00 REG_CTRL`
- `0x04 REG_STATUS`
- `0x08 REG_CFG`
- `0x14 REG_Q_BASE_L`
- `0x18 REG_Q_BASE_H`
- `0x1C REG_K_BASE_L`
- `0x20 REG_K_BASE_H`
- `0x24 REG_V_BASE_L`
- `0x28 REG_V_BASE_H`
- `0x2C REG_O_BASE_L`
- `0x30 REG_O_BASE_H`
- `0x34 REG_STRIDE_BYTES`
- `0x38 REG_NEG_LARGE`
- `0x3C REG_SCALE`
- `0x40 REG_CYCLES`
- `0x44 REG_QUEUE_CMD`
- `0x48 REG_QUEUE_STATUS`
- `0x4C REG_QUEUE_CAPACITY`
- `0x50 REG_TASK_ACCEPT_COUNT`
- `0x54 REG_TASK_DONE_COUNT`
- `0x58 REG_TASK_ERROR_COUNT`
- `0x5C REG_LAST_ERROR`
- `0x80+ PERF...`

### `REG_QUEUE_CAPACITY`

建议返回：

- `[7:0] fifo_depth`，例如 4
- `[15:8] desc_words` 或 desc_bytes/32
- `[31:16] reserved`

这有利于软件自描述。

---

## 11. 推荐实现阶段

## Phase A：接口重构

- 删除 `NEXT_*` 影子寄存器语义
- 恢复单套 baseline 任务描述寄存器为 staging regs
- 新增 `QUEUE_CMD/QUEUE_STATUS`

## Phase B：4-entry FIFO 落地

- 加入 `fifo_mem/wr_ptr/rd_ptr/count`
- 加入 `active_task_regs`
- scheduler 自动出队执行

## Phase C：计数器与异常语义

- `task_accept_count`
- `task_done_count`
- `overflow/underflow/desc_error`

## Phase D：回归验证

- FIFO 状态机级测试
- 4 任务端到端测试
- baseline 单任务兼容测试

---

## 12. 最终建议结论

### 12.1 架构结论

针对 Bonus #9，更合理的方向是：

- **删除 `NEXT_*` 双倍接口**
- **把 baseline 单套配置寄存器视为 descriptor staging port**
- **内部实现 4-entry task FIFO + active task regs + auto scheduler**

### 12.2 接口结论

- 状态接口建议使用 **完整 32-bit `QUEUE_STATUS`**，不要用模糊单编码代替；
- 命令接口建议使用 **完整 32-bit `QUEUE_CMD`**；
- Host 与队列之间采用 **逐次 ready-valid 风格的 AXI-Lite 提交流程**；
- QoS/flags/tag 建议预留字段，但首版不做复杂调度。

### 12.3 验证结论

- cocotb 中 Host 应明确建模为“连续发多次任务”的外部软件；
- 不应把 Bonus #9 的主要语义仍然建模成“一次 START 对外只看见一次 opaque done”；
- 应引入：
  - FIFO 状态测试
  - 4 任务提交测试
  - busy 期间继续 enqueue 测试
  - overflow/错误语义测试

### 12.4 数据复用结论

- FIFO 引入后确实为跨任务复用创造了观察点；
- 但首版应只完成正确的 4-entry FIFO，不把 K/V 复用优化耦合进首版 RTL；
- 可通过预留 `flags/qos/tag` 为后续复用优化铺路。
