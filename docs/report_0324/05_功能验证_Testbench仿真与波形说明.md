## 5. 功能验证——Testbench 仿真与波形说明

### 5.1 功能验证具体环境

当前功能验证环境以 Python、cocotb 和 Verilator 为主。项目根目录 `Makefile` 通过 `uv venv .venv` 建立虚拟环境，并固定安装 `cocotb==1.9.2`、`pytest` 和 `numpy`。本地实际使用的版本为：Python `3.13.5`、cocotb `1.9.2`、Verilator `5.034`、Apple clang `17.0.0`。所有 cocotb 用例均通过 `dv/cocotb/Makefile` 调度运行，构建时统一把仓库 `.venv` 注入到 `PATH` 中，以避免系统环境中不同版本的 Python 包影响仿真一致性。

对于模块级实验目录 `experiments/`，则单独维护了自己的 `Makefile`，能够直接以 `verif`、`lint`、`synth` 和 `sta` 为入口完成实验闭环。这样的组织方式使主线验证与独立 PPA 实验既共享同一套 Python 虚拟环境，又保持了各自的脚本自治性。

### 5.2 Testbench 文件描述

验证文件大致可以分为四类。第一类是算术原语与基础通路单测，例如 `test_fa_mul_sat_q8_8.py`、`test_fa_exp_pwl_8seg_q1_15.py`、`test_fa_recip_nr_q16_16.py`、`test_fa_dma_reader.py` 和 `test_fa_dma_writer.py`，用于保证局部算子的行为与接口握手正确。第二类是中层与核心模块测试，例如 `test_fa_attention_core.py`，其内部实现了内存模型、fixed-point Python 参考路径和 FP32 参考路径，能够在小参数与全参数两种配置下验证 attention 核心功能。第三类是顶层系统测试，例如 `test_fa_attention_ip_top_regs.py`，它通过 `AxiLiteMaster` 和行为级 `AxiMemoryModel` 模拟软件配置与外部存储系统，从顶层口径验证寄存器语义、DMA 事务、整轮 attention 运行和性能计数器读回。第四类是独立实验 testbench，例如 `experiments/fa_qk_dotprod_slice_pipe/tb/test_fa_qk_dotprod_slice_pipe.py`，用于对比多个实验变体之间的功能一致性。

从测试功能分布上看，当前验证体系已经覆盖了算子正确性、总线时序、配置语义、顶层运行、参考对照和性能计数这几个关键维度。虽然它还不是完整的约束随机与覆盖率驱动体系，但对当前项目阶段而言，已经能够有效发现设计 bug、握手偏差和性能计数口径问题。例如，之前顶层 perf counters 联调时，就是通过内存模型时序重写和对读写命令条数、beat 数的交叉比对，定位了 full-run 超时与统计口径不一致等问题。

### 5.3 具体功能验证说明

当前主线回归中，最重要的验证场景是 `fa_attention_core` 和 `fa_attention_ip_top` 的 full-parameter 用例。对前者而言，测试会以 `S=256`、`D=64`、`TQ=32`、`TK=64` 的默认参数构造 Q/K/V 数据，将矩阵写入仿真内存，再启动核心并等待全部 O 结果写回。测试中同时计算 fixed-point Python 参考和 FP32 参考，分别从“实现一致性”和“对算法高精度参考的偏差”两个维度给出量化结果。对后者而言，测试不仅要观察 `busy` 和 `done`，还要确认 `CTRL/STATUS` 的读写语义、DMA 命令发起情况和 perf counters 的统计值是否与内存模型计数一致。

从波形观察角度，最有代表性的信号组包括：AXI-Lite 的 `AW/W/B/AR/R` 五个通道、顶层 DMA 主口的 `AR/R/AW/W/B` 握手、核心内部 `ms` 与 `cs` 状态、`dma_rd_cmd_valid/ready` 与 `dma_wr_cmd_valid/ready`、`row_l` 和 `row_acc` 的局部更新，以及 `done` 与 `done_sticky` 的置位时刻。在当前验证流程中，虽然报告未附图形界面截图，但仿真环境已经允许通过 Verilator 导出波形并对这些关键信号进行逐拍排查。工程经验表明，绝大多数顶层级功能问题最终都能在这些信号组上被定位到明确的阶段边界。


## 5.4 0324 跨分支验证矩阵汇总

相比 0310 版本主要关注 baseline 单线，本次验证已经扩展成“主线 + bonus 线 + 推理线”的三层结构。

### 5.4.1 baseline 与系统扩展线

| 场景 | 代表配置 | 结果摘要 |
|---|---|---|
| baseline top full-run | `S=256,D=64,Q8.8` | `cycles=85928`, `MAE=0.002499`, `MaxAE=0.006583` |
| valid_len 裁剪 | `valid_len=192` | `cycles=73880`, `MAE=0.001868`, `MaxAE=0.006583` |
| 长序列 | `S=512` top/IP | `cycles=307024`, `MAE=0.002235`, `MaxAE=0.006685` |
| 外部格式 | `Q6.10/Q4.12` | top 回归通过，FP32 误差在门限内 |
| 多 head | `head=1/2/4/8` | 周期与计数严格线性扩展 |
| task queue | `FIFO_DEPTH=4/8` | 顶层回归通过，异常语义覆盖通过 |

### 5.4.2 BF16/FP16 分支验证

`exp/bonus1-bf16` 已形成模块级 + 核心级双层回归：

1. 基础模块（add/mul/exp/recip/转换）与参考模型可做到 `mismatch=0`；
2. BF16/FP16 unified core 测试通过，`precision_mode` 可切换；
3. 核心周期从 `8.57M` 优化到 `2.15M`，并保持测试口径一致。

注意：该分支验证通过并不等价于可直接替代 baseline；它验证的是低精度浮点路线的“可运行性与收敛趋势”。

### 5.4.3 INT8/FP8 分支验证

`exp/int8-fp8-bootstrap` 现已具备：

1. INT8/FP8 节点模块随机回归通过；
2. FP8 min-core/full-core/full-core-dma 测试通过；
3. RTL 与同构 fixed/cmodel 可做到逐点一致。

但与 FP32 对齐误差仍显著偏大（`MAE` 常见 3.x，`MaxAE` 常见 8.0），因此当前定位仍是“原型验证阶段”。

## 5.5 推理侧验证（native/DPI/cmodel）

### 5.5.1 DPI 路径

DPI 已完成可运行接入，但当前速度与质量仍受限：

1. 观测吞吐约 `0.023 tok/s` 量级；
2. 首 decode token 进入时间约 20 分钟量级；
3. 在误差放大场景下出现 `/API` 重复采样（mode collapse）。

### 5.5.2 cmodel 路径

cmodel 通过 mode14 修复后，已恢复可读推理并可作为稳定参考后端：

1. mode sweep 显示 mode14 `mae_lsb` 最优组（约 `0.579`，`max_abs_lsb=1`）；
2. role prompt 回归中，mode14 与 sw 输出主干可对齐；
3. 因此 cmodel 已从“实验辅助”升级为“DPI/RTL 对齐基线”。

### 5.5.3 mode15/16/17 验证状态

纯 fixed 路线（mode15/16/17）表现总结：

1. K-smooth 显著改善 chat 可读性；
2. dual-buffer/chunk 扫描中 mode17（chunk=8）当前最优；
3. 但 role prompt 结构稳定性仍不足，尚不能替代 mode14。

## 5.6 覆盖率与残余风险

当前验证体系虽已覆盖大量功能点，但仍存在两类剩余风险：

1. UVM full DUT 在 Verilator 下仍有收敛问题，控制面组合反馈路径需继续治理；
2. 推理端“数值可用性”尚未完全闭环，尤其是 mode15/17 在复杂 prompt 下的稳定性。

因此 0324 阶段结论应表述为：

- baseline 合规与主线功能稳定已完成；
- bonus 与推理扩展已形成可复现证据；
- 覆盖率工作从“单线 pass/fail”转入“多分支质量门槛分层”。
