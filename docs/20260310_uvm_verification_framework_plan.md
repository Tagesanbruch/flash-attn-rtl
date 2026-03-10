# 2026-03-10 面向 Verilator 与 VCS 双轨迁移的 UVM 验证框架设计计划

## 1. 目的与定位

本文给出当前 FlashAttention IP 的 UVM 验证框架设计计划，目标不是立刻把全部 UVM 代码一次性写完，而是先建立一套：

1. **在 Mac 本地基于 Verilator 5.034 可快速迭代；**
2. **后续可无缝迁移到服务器端 VCS 做大规模 sign-off regression；**
3. **尽量复用当前 cocotb / CModel / Verilator C++ TB 资产；**
4. **最终覆盖 AXI-Lite、AXI4 DMA、core 调度、top 数据流与性能计数器验证。**

这套方案本质上是“**本地开源快速左移验证 + 服务器商用仿真器深度覆盖**”的双轨制验证路线。

---

## 2. 方案判断：为什么现在开始做 UVM 是合适的

### 2.1 Verilator + UVM 在当前时间点已经可行

对于 2026 年的 Verilator 5.x 生态，关键点不是历史上的 `verilator/uvm` 魔改库，而是：

- Verilator 已具备动态调度（dynamic scheduling / coroutine-like scheduling）能力；
- 社区路线已转向支持**原版上游 UVM 2017**；
- 基础 class、phase、TLM、部分约束随机化都已可用；
- 在 Mac + Clang 环境下，本地构建体验反而很流畅。

因此，对当前项目来说：

- **本地搭建简单 UVM smoke 环境是现实可落地的；**
- **后续迁移到 VCS 主要是 Makefile 与仿真器切换问题，而不是重写验证源码。**

### 2.2 为什么仍然需要 VCS 作为后续目标

Verilator 当前适合：

- 环境搭建；
- agent 连线调试；
- reg read/write sanity；
- 简单双向流握手；
- 小规模随机测试；
- 本地快速修改与回归。

但真正的 sign-off 级工作仍建议放到 VCS：

- 大规模约束随机回归；
- 功能覆盖率闭环；
- 更复杂的 SVA；
- 更成熟的 class-based debug 能力；
- 企业级回归与 seed 管理。

因此，本计划不是“用 Verilator 取代 VCS”，而是：

> **用 Verilator 把 UVM 环境尽早搭起来，用 VCS 做最终深度验证。**

---

## 3. 总体验证目标

### 3.1 近期目标（P0 / P1）

1. 建立 `fa_axi_lite_regs` 的 UVM register + bus 基础环境；
2. 建立 `fa_dma_reader` / `fa_dma_writer` 的 AXI4 memory-side agent；
3. 建立 `fa_attention_ip_top` 的最小 top-level UVM smoke；
4. 跑通：
   - 配置寄存器写读；
   - `START` / `STATUS` / `DONE-STICKY`；
   - DMA 命令观察；
   - perf counters 读回。

### 3.2 中期目标（P2）

1. 建立 `fa_attention_core` / `fa_attention_ip_top` 的 scoreboard；
2. 接入 fixed-like / `rtl_strict` 黄金参考；
3. 支持 directed-random / constrained-random；
4. 建立基础覆盖率模型。

### 3.3 后期目标（P3）

1. 基于 VCS 完整 regression；
2. 覆盖率闭环；
3. 异常事务 / backpressure / long-burst / corner-case sign-off；
4. 面向长上下文和未来 block-merge 扩展预留环境结构。

---

## 4. 验证对象分层

建议按四层组织验证，而不是直接上来就做完整 top 随机回归。

### 4.1 L0：纯总线与寄存器层

对象：

- `fa_axi_lite_regs`
- `fa_dma_reader`
- `fa_dma_writer`

目标：

- 确认所有总线事务语义正确；
- 建立可复用 agent；
- 尽早验证握手、错误响应、长 burst 拆分、寄存器镜像。

### 4.2 L1：算子与 core 层

对象：

- `fa_qk_dotprod_slice`
- `fa_online_softmax_ctx`
- `fa_o_normalize_block`
- `fa_attention_core`

目标：

- 建立对 `ms/cs` 状态与 core 内数据流的验证方法；
- 为后续周期优化提供更稳定的 class-based 观测框架。

### 4.3 L2：完整 top 功能层

对象：

- `fa_attention_ip_top`

目标：

- 从 AXI-Lite 配置到 DMA 数据搬运到 O 写回形成完整闭环；
- 覆盖 perf counters 与 reg model 一致性。

### 4.4 L3：系统回归层

对象：

- 以不同 seed / traffic / backpressure / causal / non-causal / soft-reset 组合跑回归矩阵。

---

## 5. 推荐目录结构

建议在 `dv/` 下新建如下结构：

```text
dv/
  uvm/
    tb/
      top/
        fa_attention_ip_top_tb.sv
      env_pkg.sv
      test_pkg.sv
      interfaces/
        axil_if.sv
        axi_mem_if.sv
        core_mon_if.sv
    agents/
      axil/
        axil_agent.sv
        axil_driver.sv
        axil_monitor.sv
        axil_sequencer.sv
        axil_item.sv
      axi_mem/
        axi_mem_agent.sv
        axi_mem_driver.sv
        axi_mem_monitor.sv
        axi_mem_sequencer.sv
        axi_mem_item.sv
    regmodel/
      fa_attention_reg_block.sv
      fa_attention_reg_adapter.sv
      fa_attention_reg_predictor.sv
    env/
      fa_base_env.sv
      fa_attention_top_env.sv
      fa_virtual_sequencer.sv
      fa_scoreboard.sv
      fa_coverage.sv
    seq/
      axil_basic_seq.sv
      top_smoke_seq.sv
      dma_backpressure_seq.sv
      perf_counter_seq.sv
      reset_recovery_seq.sv
    tests/
      fa_base_test.sv
      fa_top_smoke_test.sv
      fa_perf_test.sv
      fa_dma_stress_test.sv
      fa_reset_recovery_test.sv
    sv/
      uvm_filelist.f
    sim/
      Makefile
      verilator.mk
      vcs.mk
```

该结构的原则是：

- bus agent 与 env 解耦；
- reg model 单独维护；
- 序列与测试分层；
- 仿真器切换只影响 `sim/` 下的构建文件。

---

## 6. 核心组件设计

### 6.1 AXI-Lite Agent

#### 目标

覆盖：

- 寄存器写地址/写数据分离到达；
- 读写响应；
- 启动脉冲；
- done-sticky 清除；
- soft reset；
- perf window 读回。

#### 组成

- `axil_item`
- `axil_driver`
- `axil_monitor`
- `axil_sequencer`
- `axil_agent`

#### monitor 需要采集的重点

1. `AW/W/B/AR/R` 事务边界；
2. `CTRL` 写 `START` 脉冲；
3. `STATUS` 中 `busy/done/error`；
4. `PERF_*` 读回值。

### 6.2 AXI4 Memory Agent

#### 目标

面向 top 验证 `m_axi_*` 五通道，模拟外部 memory system。

#### 组成

- `axi_mem_item`
- `axi_mem_driver`
- `axi_mem_monitor`
- `axi_mem_agent`

#### driver 需要支持的行为

1. 读地址命令接收；
2. R 通道 beat 返回；
3. 写地址接收；
4. W 通道 beat 消费；
5. B 通道响应；
6. backpressure / latency / response injection。

#### 可选模式

- `zero-latency memory`
- `fixed-latency memory`
- `random-latency memory`
- `error-injection memory`

### 6.3 Register Model

推荐基于标准 UVM RAL 建立 `fa_attention_reg_block`，覆盖：

- `CTRL`
- `STATUS`
- `CFG`
- `Q/K/V/O_BASE`
- `STRIDE_BYTES`
- `NEG_LARGE`
- `SCALE`
- `CYCLES`
- `PERF_*`

#### 重点能力

1. mirror / predict；
2. `done-sticky` 写 1 清；
3. `START` 作为 pulse register 的特殊访问语义；
4. 读写权限约束；
5. 默认值检查。

### 6.4 Scoreboard

建议 scoreboard 分成三层：

#### 层 A：总线一致性 scoreboard

检查：

- AXI-Lite 请求/响应一一对应；
- AXI4 命令/beat 数与期望一致；
- 读写 burst 长度合法。

#### 层 B：行为统计 scoreboard

检查：

- `PERF_*` 与 monitor 统计一致；
- DMA cmd / beat 数与 memory monitor 一致；
- `run_count` / `busy_cycles` / `cs_*` 读回与行为吻合。

#### 层 C：数值结果 scoreboard

检查：

- O 写回数据与黄金参考一致或在误差门限内；
- 同时保留：
  - `fixed-like` 口径；
  - `rtl_strict` 口径；
  - `FP32` 口径。

这里建议最终以 `rtl_strict` 作为主硬件等价参考，以避免当前 `ctx` 主线与旧 fixed-q8.8 参考口径不一致的问题。

### 6.5 Coverage

推荐从一开始就放入 coverage collector，但前期只做最关键 bins。

#### 功能覆盖建议

1. `causal_en`：`0/1`
2. `soft_reset`：空闲时 / busy 时
3. DMA 读命令长度：短 / 中 / 满 burst / split burst
4. DMA 写命令长度：正常 / backpressure 下完成
5. `STATUS`：busy / done / error
6. perf window：全部窗口至少被读取一次
7. 测试输入分布：
   - small-int
   - wider int range
   - near-overflow patterns
8. top completion：
   - 正常结束
   - reset 中断
   - response error

#### 交叉覆盖建议

- `causal_en × input_mode`
- `memory_latency_mode × dma_split_mode`
- `soft_reset_timing × busy_state`
- `error_injection × status/error register`

---

## 7. 序列与测试计划

### 7.1 P0：最小 smoke

#### `fa_top_smoke_test`

目标：

1. 复位后默认寄存器值；
2. 配置 `BASE/STRIDE/SCALE/NEG_LARGE/CFG`；
3. 写 `START`；
4. 轮询 `STATUS`；
5. 读取 `CYCLES` / `PERF_*`；
6. 检查 done-sticky。

### 7.2 P1：总线与寄存器 directed tests

#### 建议测试

- `fa_reg_defaults_test`
- `fa_reg_permission_test`
- `fa_start_busy_done_test`
- `fa_soft_reset_during_busy_test`
- `fa_perf_window_read_test`

### 7.3 P2：DMA/Memory stress tests

#### 建议测试

- `fa_dma_backpressure_test`
- `fa_dma_random_latency_test`
- `fa_dma_split_burst_test`
- `fa_dma_error_response_test`

### 7.4 P3：数据流与数值一致性 tests

#### 建议测试

- `fa_top_fixed_like_compare_test`
- `fa_top_rtl_strict_compare_test`
- `fa_top_fp32_compare_test`
- `fa_seed_sweep_test`

### 7.5 P4：周期与 perf correctness tests

#### 建议测试

- `fa_perf_counter_consistency_test`
- `fa_ms_cs_sum_check_test`
- `fa_compute_overlap_regression_test`
- `fa_qk_streaming_experiment_test`
- `fa_ctx_overlap_experiment_test`

---

## 8. 与现有 cocotb / CModel / C++ TB 的衔接方式

### 8.1 复用 cocotb 现有结论

当前 cocotb 已经有三类高价值资产：

1. 顶层寄存器行为；
2. DMA 行为级 memory model；
3. perf counter 一致性检查。

UVM 初期不需要推翻这些，而应把它们转化为：

- directed sequence 规范；
- monitor 检查点；
- scoreboard 对账规则。

### 8.2 复用 CModel

`cmodel rtl_strict` 应作为后续 UVM 数值层黄金参考的主路线，原因是：

- 当前主线 softmax 已切到 `ctx`；
- 旧 fixed-q8.8 参考不再严格等价；
- `rtl_strict` 更适合成为 class-based scoreboard 的软件后端。

推荐两种集成方式：

1. **短期**：测试前离线生成 reference 文件，UVM scoreboard 读取；
2. **中期**：通过 DPI-C 直接调用 CModel。

### 8.3 复用 Verilator C++ TB

C++ TB 不直接并入 UVM，但可以作为：

- `fa_attention_core` profile 对照工具；
- 调度问题定位工具；
- UVM 周期/状态统计异常时的快速对比基线。

---

## 9. Verilator 与 VCS 的双编译流设计

### 9.1 总体原则

验证源码尽量保持纯标准 SystemVerilog/UVM 语法；
只在仿真器差异明显的地方使用条件编译宏。

### 9.2 Makefile 目标建议

建议在 `dv/uvm/sim/Makefile` 中支持：

- `make sim_verilator TEST=fa_top_smoke_test`
- `make sim_vcs TEST=fa_top_smoke_test`
- `make regress_verilator TESTLIST=smoke.list`
- `make regress_vcs TESTLIST=nightly.list`

### 9.3 条件编译策略

若遇到 Verilator 与 VCS 的边缘差异，可采用：

```systemverilog
`ifdef VERILATOR
  // 更保守的写法
`else
  // VCS 下的完整写法
`endif
```

但使用原则应是：

- 只在必须时使用；
- 尽量不污染 sequence / scoreboard 主逻辑；
- 差异主要限制在 utility / macro / randomization 边缘部分。

---

## 10. 本地 Verilator 路线的落地策略

### 10.1 首批建议支持的能力

本地 Verilator 先只要求跑通：

1. `axil_agent`
2. `axi_mem_agent`
3. `reg model`
4. `top smoke test`
5. `perf counter consistency smoke`

### 10.2 暂不强求的能力

在 Verilator 本地阶段，可先不强求：

- 大规模覆盖率闭环；
- 极复杂随机约束；
- 大量 SVA temporal property；
- 海量 seed regression。

这些在第二阶段转到 VCS 更合理。

---

## 11. VCS 服务器阶段的落地策略

当本地环境成熟后，迁移到 VCS 时建议按以下顺序推进：

1. 先跑与本地完全相同的 smoke list；
2. 再启用更强随机约束；
3. 再启用覆盖率采集；
4. 再加入 nightly / weekly regression matrix。

建议的服务器 regression 分类：

- `smoke`
- `bus_nightly`
- `top_random_nightly`
- `perf_weekly`
- `error_injection_weekly`
- `coverage_closure`

---

## 12. 分阶段实施计划

### P0：两周内可落地的最小环境

目标：

- 搭起目录；
- 跑通 Verilator + UVM 基础编译；
- 建立 `axil_if`、`axi_mem_if`；
- 完成 `fa_top_smoke_test`。

产出：

- `dv/uvm/` 初始框架；
- `sim_verilator` 可运行；
- 本地寄存器和基本 DMA 握手可通。

### P1：一个月内的 bus 完整化

目标：

- 完成 AXI-Lite / AXI memory 两个 agent；
- 完成 register model；
- directed tests 覆盖寄存器与 DMA 基本语义。

### P2：两个月内的 top 数据流验证

目标：

- 接入 scoreboard；
- 接入 `rtl_strict` 参考；
- 支持 top full-run directed/random。

### P3：服务器迁移与覆盖率闭环

目标：

- VCS 编译流稳定；
- nightlies 成形；
- 功能覆盖率开始闭环。

---

## 13. 当前项目最适合先做的 UVM 子集

结合当前工程状态，最建议优先落地的不是完整重兵团环境，而是以下三件事：

1. **AXI-Lite register UVM**
   - 因为 top 控制面已经稳定；
   - 寄存器语义明确；
   - perf window 很适合 RAL 建模。

2. **AXI memory-side UVM agent**
   - 因为 DMA reader/writer 已经是稳定边界；
   - 未来所有 top 级验证都离不开它。

3. **top perf consistency scoreboard**
   - 当前工程的核心问题之一就是周期和调度；
   - 因此 UVM 第一个真正体现价值的点，不是花哨随机化，而是把 perf / 行为 / 结果三者统一约束住。

---

## 14. 风险与规避方案

### 风险 1：Verilator 对部分 UVM 特性支持不完整

规避：

- 本地只做 smoke 与基础 agent；
- 高级随机与覆盖率留给 VCS。

### 风险 2：UVM 与现有 cocotb 重复建设

规避：

- cocotb 保留为快速脚本回归；
- UVM 聚焦标准化环境、coverage、长期 sign-off。

### 风险 3：黄金参考口径混乱

规避：

- 尽快统一到 `rtl_strict` 为主参考；
- fixed-like 仅保留历史对照意义。

### 风险 4：环境搭太大导致迟迟无法跑通

规避：

- 严格按 P0 -> P1 -> P2 推进；
- 先 smoke，后 random，最后 coverage。

---

## 15. 结论

对当前项目而言，最合理的 UVM 路线不是直接上重型商用流，而是：

1. **在 Mac + Verilator 5.034 上先把标准 UVM 骨架搭起来；**
2. **先围绕 AXI-Lite、AXI DMA 和 top smoke 打通最小闭环；**
3. **以 `rtl_strict` 作为后续数值 scoreboard 主参考；**
4. **后续迁移到服务器端 VCS 做大规模 constrained-random 与 coverage closure。**

这套路线既能充分复用当前已有 cocotb / CModel / Verilator C++ TB 资产，又能把验证体系从“脚本驱动回归”升级到“标准化可迁移 UVM 环境”，非常适合当前 FlashAttention IP 从 baseline 走向更强工程化阶段的需求。
