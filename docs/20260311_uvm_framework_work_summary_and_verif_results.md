# UVM验证框架阶段总结与关键验证结果（2026-03-11）

## 1. 本阶段目标与完成度

### 目标
- 在 Verilator 上完成 `dv/uvm` 框架可运行化。
- 消除 time-0 的 `DIDNOTCONVERGE`，至少形成可复现定位和可验证修复路径。
- 形成工程化、可追溯的调试记录与验证证据。

### 当前完成状态
- UVM 基础框架（agent/env/regmodel/test）已成型并可编译。
- 最小 UVM+Verilator 用例可稳定通过。
- Full DUT 仍存在 `NBA DIDNOTCONVERGE`，但已从“未知大问题”收敛到“明确子模块范围（`fa_axi_lite_regs`）”。

## 2. 验证框架设计思路（Design Rationale）

### 2.1 分层结构
- Top TB：`dv/uvm/tb/top/fa_attention_ip_top_tb.sv`
- Agent层：
  - AXI-Lite 控制面 agent
  - AXI memory 数据面 agent
- Env层：组合 agent、scoreboard、sequencer 组织验证场景
- Test/Sequence层：`fa_base_test` / `fa_top_smoke_test` / `fa_perf_test`

### 2.2 调试策略
- 采用“先框架稳定，再功能覆盖”的顺序：
  1. 先保证 UVM+Verilator 调度收敛
  2. 再推进 smoke/perf 场景
- 采用“最小化+二分”方法：
  - 最小 DUT/最小测试先验证基础调度
  - 再逐步恢复 DUT 子模块定位问题源

### 2.3 工程约束下的构建策略
- 避免 full clean（编译耗时大，且用户要求保留底层库产物）
- 仅删除 `__verFiles.dat` 强制重verilate，保留重型目标文件缓存

## 3. 已解决问题

### 3.1 Driver类代码中的NBA死循环
- 现象：`NBA region did not converge`
- 根因：class driver 中对 VIF 使用 `<=`（NBA），触发 Verilator `__VnbaEvent` 循环
- 修复：将 driver 中 VIF 驱动改为阻塞赋值 `=`
- 涉及文件：
  - `dv/uvm/agents/axi_mem/fa_axi_mem_driver.sv`
  - `dv/uvm/agents/axil/fa_axil_driver.sv`

### 3.2 UVM wait_for_nba_region 在 Verilator 场景的兼容性
- 在最小用例中验证了 `uvm_wait_for_nba_region` 路径会触发收敛问题
- 兼容修复：`uvm_globals.svh` 中对 Verilator 走 `#1step` workaround
- 涉及文件：`dv/uvm/lib/uvm-verilator/src/base/uvm_globals.svh`

## 4. 关键验证测试与结果

> 日志目录：`dv/uvm/build/reports/`

### 4.1 测试矩阵

1. `minimal_test`（最小UVM验证）
- 命令：`./build/Vminimal_tb +UVM_TESTNAME=minimal_test +UVM_VERBOSITY=UVM_LOW`
- 日志：`dv/uvm/build/reports/minimal_test.log`
- 结果：PASS
- 关键证据：
  - `Running test minimal_test`
  - `MINIMAL_TB: PASS`
  - `Verilog $finish`
  - `$finish at 165ps`

2. `fa_base_test`（Full DUT）
- 命令：`make -C dv/uvm/sim sim_verilator TEST=fa_base_test BUILD_JOBS=8`
- 日志：`dv/uvm/build/reports/fa_base_full.log`
- 结果：FAIL
- 关键证据：
  - `Running test fa_base_test`
  - `%Error-DIDNOTCONVERGE ... NBA region did not converge ...`

3. `fa_base_test`（仅禁用 PERF）
- 命令：`... EXTRA_DEFINES='+define+FA_UVM_DISABLE_PERF'`
- 日志：`dv/uvm/build/reports/fa_base_disable_perf.log`
- 结果：FAIL
- 结论：问题不在 perf counter 模块

4. `fa_base_test`（仅禁用 REGS）
- 命令：`... EXTRA_DEFINES='+define+FA_UVM_DISABLE_REGS'`
- 日志：`dv/uvm/build/reports/fa_base_disable_regs.log`
- 结果：PASS
- 关键证据：
  - `Running test fa_base_test`
  - `Verilog $finish`
  - `$finish at 36ps`
- 结论：`fa_axi_lite_regs` 是当前收敛问题主嫌疑点

## 5. 当前验证领域关注点（Verification-Critical Focus）

### 5.1 调度稳定性（最高优先级）
- 关注：time-0 delta-cycle / NBA 收敛
- 当前结论：问题集中到 `rtl/bus/fa_axi_lite_regs.sv`

### 5.2 控制面握手健壮性（AXI-Lite）
- 关注：`awready/wready/bvalid` 与 `arready/rvalid` 组合反馈路径
- 风险：组合路径与时序寄存互相触发，导致零时间反复调度

### 5.3 环境-被测隔离能力
- 已实现宏开关快速隔离：
  - `FA_UVM_DISABLE_DUT`
  - `FA_UVM_DISABLE_CORE`
  - `FA_UVM_DISABLE_DMA`
  - `FA_UVM_DISABLE_REGS`
  - `FA_UVM_DISABLE_PERF`
- 价值：可快速建立最小失败复现，支持后续提交上游问题

## 6. 本阶段产出文件
- 调试报告：`docs/20260311_uvm_verilator_didnotconverge_debug_report.md`
- 阶段总结（本文）：`docs/20260311_uvm_framework_work_summary_and_verif_results.md`
- 最小验证用例：`dv/uvm/tests/minimal/minimal_tb.sv`
- 关键日志：
  - `dv/uvm/build/reports/minimal_test.log`
  - `dv/uvm/build/reports/fa_base_full.log`
  - `dv/uvm/build/reports/fa_base_disable_perf.log`
  - `dv/uvm/build/reports/fa_base_disable_regs.log`

## 7. 下一步建议（已具备执行条件）
1. 先对 `fa_axi_lite_regs.sv` 做“握手路径去组合反馈”修复（优先寄存化 ready/valid 关键路径）。
2. 先回归 `fa_base_test`（快速判定收敛），再回归 `fa_top_smoke_test`。
3. 在稳定后补充控制面覆盖点：reset后首笔读写、背压、并发读写竞争、状态清零语义。
