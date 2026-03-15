# 2026-03-15 FP8 IP 与 Q8.8 主线/题意对齐清单

## 1. 对齐目标

在进入全核验证前，确保 FP8 路径与现有 Q8.8 主线在以下维度严格对齐：

1. 控制面语义（寄存器位定义、启动/忙闲/完成行为）；
2. 数据面边界（shape、stride、tile 顺序、buffer 访问时序）；
3. 性能口径（cycle 统计与 perf counter 定义）；
4. 题意约束（精度、时延、吞吐、接口协议）。

## 2. 必做对齐项

### 2.1 寄存器与状态机

1. `start/busy/done` 时序与 Q8.8 语义一致；
2. 配置寄存器读写权限、默认值、sticky 位与 W1C 语义一致；
3. round/sat/scale/mode 位定义与主线命名保持统一。

### 2.2 数据路径与 tile 调度

1. Q/K/V 的 tile 扫描顺序与 Q8.8 主线一致；
2. score/softmax/ctx 的中间缓存命名与生命周期一致；
3. backpressure 与握手行为在 flush/bubble 场景与主线一致。

### 2.3 性能计数口径

1. compute/dp_run/score_done/softmax_prep 计数定义复用主线口径；
2. cycle 统计起止条件与 Q8.8 回归完全一致；
3. 在同 shape 下输出可直接横向比较。

### 2.4 精度与题意指标

1. 与 golden 的误差口径（MAE/MaxAE）保持一致；
2. corner case（NaN/Inf/Subnormal/overflow）策略可配置且可验证；
3. 所有题意约束项对应到可观测测试指标。

## 3. 全核验证前置门槛

1. 模块级：QK/softmax/PV/mma 单元全部 PASS；
2. 子系统级：tile 调度 + 控制面 + perf counter PASS；
3. 顶层级：与现有 `fa_attention_ip_top` 回归框架对接通过；
4. 报告级：输出“对齐矩阵 + 指标差异 + 残余风险”。

## 4. 下一步执行建议

1. 先做寄存器语义对齐并接入 FP8 控制位；
2. 再做 tile 调度与 perf counter 口径对齐；
3. 最后进入全核回归（含题意约束核验）。

## 5. 当前 FP8 Full Core 与 Q8.8 RTL 的差异清单（本轮复核）

对比对象：

1. `experiments/fp8/fa_fp8_attention_core_full/base/fa_fp8_attention_core_full.sv`
2. `rtl/core/fa_attention_core.sv`

### 5.1 控制与接口层

已具备：

1. `start/busy/done` 基本控制语义；
2. `cycle_count` 输出；
3. 参数化 `DOT_ENGINES/ROW_PAR/OVERLAP_EN` 的性能建模钩子。

缺失项：

1. 尚未接入 AXI-Lite CSR（`CTRL/STATUS/CFG`）读写面；
2. 尚未接入 DMA 命令/数据握手通道（Q/K/V/O 仍为本地写口建模）；
3. 尚未形成 top-level 可直接替换的总线协议封装。

### 5.2 数据搬运与 tile 组织

已具备：

1. 行级完整路径：`QK score -> online softmax -> PV accum -> ctx`；
2. 支持多行运行，结果可读回。

缺失项：

1. 没有 Q tile/KV tile 的双缓冲预取与 bank 切换；
2. 没有与外部存储一致的 stride/base 地址时序；
3. 没有与主线一致的 `LOAD_Q/LOAD_K/LOAD_V/WRITE_O` 主状态机节拍。

### 5.3 计算调度与流水深度

已具备：

1. 点积并行度参数化（`DOT_ENGINES`）；
2. 行并行与阶段重叠的周期估算（`ROW_PAR/OVERLAP_EN`）。

缺失项：

1. 当前实现为“功能上逐行完成 + 周期上估算并行”，并非真实多槽并行流水；
2. 没有 Q8.8 主线的 `ctx slot` 粒度执行与回写冲突管理；
3. softmax 非线性阶段仍是行内组合流程，未拆成可回压流水段。

### 5.4 Perf counter 口径

本轮已补：

1. RTL 内部 perf 寄存器（run/busy/rows/score/softmax/pv/ctx_write）；
2. cocotb 用例改为直接校验这些 RTL 计数值。
3. 轻量 CSR 读口地址映射（status/cycles/perf）已接入 FP8 full core。
4. perf CSR 地址已对齐 `fa_axi_lite_regs` 口径（`0x80~0xD4`）。
5. DMA 相关 perf（cmd/beat）已从全零升级为模型化统计并可经 CSR 读出。
6. Tile 主状态机分段计数（`LOAD_Q/INIT/LOAD_K/LOAD_V/COMPUTE/NORMALIZE/WRITE_O/NEXT_Q`）已接入 CSR 字段（当前为模型化分段，非真实握手驱动）。
7. `cycle_count` 与核心分段 perf 计数已从“估算累加”切换为“真实状态周期累加”。

仍待补齐：

1. 补齐所有已对齐地址背后的“严格同语义”统计定义（当前 DMA 与部分 master-state 项仍为 0 或近似映射）；
2. 与 Q8.8 主线同名分层计数（master-state 与 compute-substate）的一一对齐；
3. DMA 相关计数（cmd/beat）目前为空。

## 6. 结论

1. 当前 FP8 full core 适合做“功能正确 + 性能趋势建模 + 参数探索”；
2. 距离“可直接并入现有 IP 顶层”仍差控制总线、DMA 接口、真实 tile 流水三块；
3. perf 计数已从 testbench 迁移到 RTL 侧，满足“不能只在 cocotb 层统计”的要求，但寄存器总线映射仍需下一步接入。

## 7. rtl/core 全文件复核记录（7/7）

本节基于 `rtl/core` 目录 7 个文件逐一通读，不依赖关键词抽样。

1. `fa_attention_core.sv`：当前主线真实工作核心，包含 master state、DMA、prefetch、compute、normalize、write-back 及 perf hooks。
2. `fa_qk_dotprod_slice.sv`：被 `fa_attention_core.sv` 例化，7 级流水加法树完成 chunk 点积。
3. `fa_online_softmax_ctx.sv`：被 `fa_attention_core.sv` 例化，4 组上下文状态 + 多级流水更新 `m/l/acc`。
4. `fa_o_normalize_block.sv`：被 `fa_attention_core.sv` 例化，完成 `acc * recip` 归一化与饱和。
5. `fa_row_context_rf.sv`：为早期/替代实现风格的上下文 RF；当前 `fa_attention_core.sv` 内部直接使用数组状态，未例化该模块。
6. `fa_tile_compute_engine.sv`：早期 tile 级引擎雏形，存在状态注释与实际逻辑未完全闭合（例如 `PV_INIT/PV_RUN`）；当前主线未例化。
7. `fa_online_softmax_pair.sv`：当前仓库未被任何模块例化，确认为非主路径参考模块。
