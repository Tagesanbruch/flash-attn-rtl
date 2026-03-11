# 2026-03-12 Bonus #2 进展：标准 MHA 最小实现（第一阶段）

## 1. 本轮目标

本轮不是直接做 GQA/MLA，而是先把当前单 head top/IP 扩展成**标准 MHA 的最小可运行版本**。

当前实现策略是：

- **不改 `fa_attention_core` 的单 head 计算本体**；
- 在 top 级增加一个 **head 顺序调度器**；
- 对每个 head 依次复用同一个 core；
- 通过 head 基址偏移完成 `Q/K/V/O` 多 head 数据访问。

这属于“最小侵入、容易归因”的第一阶段实现。

## 2. RTL 改动

### 2.1 新增寄存器

在 [rtl/bus/fa_axi_lite_regs.sv](rtl/bus/fa_axi_lite_regs.sv) 中新增：

- `REG_NUM_HEADS = 0x44`
- `REG_HEAD_STRIDE = 0x48`

语义：

- `NUM_HEADS`：本次运行要顺序执行的 head 数；
- `HEAD_STRIDE`：相邻两个 head 的基地址字节偏移；
- 当 `HEAD_STRIDE=0` 时，top 使用 `SEQ_LEN * STRIDE_BYTES` 作为默认 head 间距。

### 2.2 top 级调度

在 [rtl/top/fa_attention_ip_top.sv](rtl/top/fa_attention_ip_top.sv) 中新增：

- `effective_num_heads`
- `effective_head_stride_bytes`
- `active_head_idx`
- `launch_pending`
- `completed_head_cycles`
- `run_cycles_hold`

实现方式：

1. 软件写一次 `START`；
2. top 级把它展开成多个内部 `core_start_pulse`；
3. 每个 head 完成后自动切到下一个 head；
4. `STATUS/DONE/CYCLES` 面向整个多 head run 聚合；
5. `fa_attention_core` 仍保持单 head 语义不变。

也就是说，本轮实际上完成的是：

> **single-core sequential MHA**

而不是多 core 并行 MHA。

## 3. 验证改动

在 [dv/cocotb/tests/test_fa_attention_ip_top_regs.py](dv/cocotb/tests/test_fa_attention_ip_top_regs.py) 中补了两类验证：

1. **寄存器验证**
   - 检查 `NUM_HEADS/HEAD_STRIDE` 默认值与 R/W 行为；
2. **2-head top full-run 验证**
   - 新增 `test_multihead_two_head_full_run`
   - 生成 2 组 `Q/K/V`
   - 用 head stride 连续布局到 memory model
   - 检查输出、周期和关键 perf counter。

同时原有 full-run 测试也已扩成支持 `TOP_TEST_NUM_HEADS` 环境变量，从而可以复用同一套 top 回归框架做多 head 扩展测试。

## 4. 本轮结果

已实测通过：

- `make test MODULE=fa_attention_ip_top`
- top cocotb 共 5 项测试全部通过
- `TOP_TEST_NUM_HEADS=4 TESTCASE=test_perf_counters_full_run make -C dv/cocotb MODULE=fa_attention_ip_top test`
- `TOP_TEST_NUM_HEADS=8 TESTCASE=test_perf_counters_full_run make -C dv/cocotb MODULE=fa_attention_ip_top test`

其中新增 2-head case 的关键结果为：

- `cycles = 171856`
- `comp_launch = 128`
- `recip_req = 512`
- `wr_cmd = 16`
- 相对 fixed-like：`max_err_lsb = 0`
- 相对 FP32：`max_err_fp32 = 0.006799`

这说明：

1. 两个 head 已按顺序完整执行；
2. `comp_launch / recip_req / wr_cmd` 等计数器按 head 数正确放大；
3. 当前最小实现没有破坏单 head 数值正确性；
4. 2-head 结果仍显著低于题目误差门限。

进一步，`head=4` 与 `head=8` 也已完成 top/IP 级 full-run 验证：

### `head=4`

- `cycles = 343712`
- `comp_launch = 256`
- `recip_req = 1024`
- 相对 FP32：`MAE = 0.002401`，`MaxAE = 0.008180`

### `head=8`

- `cycles = 687424`
- `comp_launch = 512`
- `recip_req = 2048`
- 相对 FP32：`MAE = 0.002369`，`MaxAE = 0.008180`

可以看到，当前第一阶段实现呈现出非常清晰的特征：

- 周期与主要计数器基本按 head 数线性放大；
- 数值误差没有因为 head 数增加而明显恶化；
- `head=4/8` 仍稳定满足题目误差门限。

## 5. 当前定位

这版实现的定位应明确为：

- **Bonus #2 第一阶段最小落地版**；
- 优先验证“标准 MHA 可运行、接口可配置、验证可闭环”；
- 暂不追求：
  - GQA
  - MLA
  - 多 head 并行 overlap
  - head 级专门 buffer 复本

## 6. 下一步自然演进

如果继续推进 Bonus #2，更自然的后续工作是：

1. 补 `head=4/8` 的回归；
2. 补多 seed / 多 causal 配置覆盖；
3. 评估 `head` 循环与 perf counter 的更细粒度拆账；
4. 再决定是否要进入更激进的跨 head overlap 或 shared-buffer 调度。
