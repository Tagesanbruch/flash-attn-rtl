## 6. UVM 验证——模块功能和完整性测试

### 6.1 UVM 验证结构

UVM 体系目前尚未正式落地，但设计边界已经足够清晰。若进入下一阶段实现，建议将验证平台拆分为 AXI-Lite agent、AXI4 memory agent、寄存器模型、scoreboard、coverage collector 与虚拟序列六个主要部分。AXI-Lite agent 负责寄存器配置与轮询完成，AXI4 memory agent 则负责行为级存储阵列与突发事务。寄存器模型应覆盖当前 `CTRL/STATUS/CFG/BASE/STRIDE/SCALE/PERF` 全部窗口，并支持 `done-sticky` 的写 1 清行为。scoreboard 一方面对比写回的 O 矩阵，另一方面核对 DMA 事务条数和性能计数器口径。虚拟序列则负责组织短序列、全序列、causal/non-causal、错误注入、背靠背任务和长时间稳定性测试等场景。

从结构上看，现有 cocotb 验证已经为 UVM 搭建提供了相当完整的参考：内存模型可以映射到 AXI agent，现有 Python 参考可以迁移为 DPI-C 或离线黄金模型，寄存器访问路径则可以直接转化为 reg model 序列。因此，UVM 的工程量主要体现在把当前脚本化验证重构成类层次清晰、覆盖率可统计、随机约束可扩展的体系，而不是从零开始重建全部行为语义。

### 6.2 UVM 验证结果

截至本报告写作时，UVM 还未启动编码，因此暂无覆盖率统计、回归通过率或约束随机结果可汇报。这一节保留为后续阶段的规划接口。考虑到当前 baseline 功能、周期与精度已经具备稳定基础，下一阶段若进入更强的 SoC 集成和 bonus 功能开发，UVM 平台将成为验证复杂数据流、异常事务和系统互联边界条件的自然下一步。


## 6.3 0324 UVM 进展与定位重定义

0310 时 UVM 仍在计划态；0324 时已进入“框架可编译、最小用例可跑、full DUT 仍待收敛”的中间状态。该状态虽然还不能作为主验收入口，但已经具备工程价值。

### 6.3.1 已完成

1. `agent/env/regmodel/test` 基础骨架可编译运行；
2. `minimal_test` 在 Verilator 稳定 PASS；
3. 驱动侧 NBA 死循环问题已定位并修复（class driver 中 `<=` 改阻塞赋值）。

### 6.3.2 未完成

1. `fa_base_test` 在 full DUT 下仍可能触发 `DIDNOTCONVERGE`；
2. 分层隔离显示问题主嫌疑集中在 `fa_axi_lite_regs` 交互路径；
3. 因此 UVM 尚不能替代 cocotb 成为 baseline 的主 gate。

### 6.3.3 当前工程策略

当前策略不是“等待 UVM 完成再开发”，而是双轨：

1. cocotb 继续承担主回归和功能验收；
2. UVM 继续承担协议级、调度级问题定位与后续覆盖率平台建设。

这保证了交付进度不被单一仿真后端阻塞。

## 6.4 下一阶段 UVM 最小闭环目标

建议将 UVM 目标收敛到可执行的三步：

1. 先修 `fa_axi_lite_regs` 的组合反馈收敛问题；
2. 让 `fa_base_test` 稳定 through；
3. 再迁移 cocotb 已稳定的 L1/L2 用例（寄存器、queue、head 配置）到 UVM sequence 库。

在此之前，不建议把“UVM 覆盖率数字”作为对外核心指标，以免误导当前成熟度判断。
