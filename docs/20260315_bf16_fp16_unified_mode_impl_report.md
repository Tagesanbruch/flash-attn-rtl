# 2026-03-15 BF16/FP16 统一模式实现与验证报告

## 1. 本轮完成项

本轮完成了 `fa_attention_core_bf16fp32` 的单 RTL 双模式实现：

1. 新增运行时模式输入 `i_precision_mode`：
   - `0`: BF16
   - `1`: FP16
2. 输入路径支持 BF16/FP16 二选一解码到 FP32；
3. 输出路径支持 FP32 下变换到 BF16/FP16；
4. golden model 支持 `input_fmt/output_fmt`，用于 BF16/FP16 同一套参考验证；
5. cocotb testbench 新增 FP16 noncausal/causal 两条测试。

## 2. 代码变更

核心 RTL：

- `experiments/bf16/fa_attention_core_bf16fp32/base/fa_attention_core_bf16fp32.sv`
  - 增加 `i_precision_mode`
  - 同时实例化 `fa_bf16_to_fp32` 与 `fa_fp16_to_fp32`，按 mode 选择
  - normalize 输出增加 `fa_fp32_to_fp16`，按 mode 写回 `o_buf`

新增转换模块：

- `experiments/bf16/fa_attention_core_bf16fp32/base/fa_fp16_to_fp32.sv`
- `experiments/bf16/fa_attention_core_bf16fp32/base/fa_fp32_to_fp16.sv`

golden 与测试：

- `experiments/bf16/common/golden_models.py`
  - 新增 `fp16_to_fp32_bits`
  - 新增 `fp32_to_fp16_bits`
  - 新增 `f16x_to_fp32_bits` / `fp32_to_f16x_bits`
  - `attention_bf16_fp32_reference` 新增 `input_fmt/output_fmt`
- `experiments/bf16/fa_attention_core_bf16fp32/tb/test_fa_attention_core_bf16fp32.py`
  - `run_case(..., precision_mode)`
  - 新增 `test_attention_core_noncausal_fp16`
  - 新增 `test_attention_core_causal_fp16`
  - 默认 timeout 上调到 9,000,000 cycles（匹配当前 2M+ 周期现实）

## 3. 功能验证结果

执行命令：

```bash
make -C experiments verif MOD=bf16/fa_attention_core_bf16fp32 EXP=base
```

结果：`PASS=5, FAIL=0`

通过项：

1. `test_attention_core_trace_first_divergence`（按配置默认 skip）
2. `test_attention_core_noncausal`（BF16）
3. `test_attention_core_causal`（BF16）
4. `test_attention_core_noncausal_fp16`（FP16）
5. `test_attention_core_causal_fp16`（FP16）

关键观测：

- BF16 noncausal: `cycles=2,150,497`, `MAE=0.000000`, `MaxAE=0.000000`
- BF16 causal: `cycles=2,150,497`, `MAE=0.000000`, `MaxAE=0.000000`
- FP16 noncausal: `cycles=2,150,497`, `MAE=0.000000`, `MaxAE=0.000000`
- FP16 causal: `cycles=2,150,497`, `MAE=0.000000`, `MaxAE=0.000000`

perf 计数（四条主测一致）：

- `compute=2,097,152`
- `dp_run=1,048,576`
- `score_done=65,536`
- `softmax_prep=983,040`
- `lane_idle=0`
- `tile_switch_bubbles=24`

结论：

1. 双模式没有引入周期回退；
2. BF16 基线行为保持一致；
3. FP16 模式已在相同调度框架下跑通。

## 4. 实现说明与边界

1. 当前 softmax 标量更新模块仍使用 BF16 score 输入路径（由 FP32 score 下变换得到），此行为在 BF16/FP16 两种 mode 下一致；
2. mode 主要作用于 Q/K/V 输入解释和 O 输出编码；
3. 这种实现最小化了对核心状态机与 perf counter 语义的扰动。

## 5. 下一步建议

1. 将 `i_precision_mode` 向上接入顶层寄存器（AXI-Lite 可配置）；
2. 增加 FP16 边界值测试集（Inf/NaN/Subnormal/极值）；
3. 对 `fa_fp16_to_fp32` 与 `fa_fp32_to_fp16` 做模块级 AE/cmodel 对比脚本，形成独立误差报告；
4. 若要继续提速，优先继续跨 pair 流水重叠，不优先改 DMA。

---

## 6. 追加完成项（按 2026-03-15 后续指令）

根据后续要求，本轮又完成了三项追加工作：

1. 顶层寄存器可配置 `precision_mode` 语义接入；
2. `fa_fp16_to_fp32` / `fa_fp32_to_fp16` 模块级单测补齐；
3. 顶层回归验证寄存器改动未破坏主线行为。

### 6.1 顶层寄存器接入

变更：

- `rtl/bus/fa_axi_lite_regs.sv`
  - 新增输出 `o_precision_mode`
  - 定义 `o_precision_mode = reg_cfg[1]`
- `rtl/top/fa_attention_ip_top.sv`
  - 接线 `precision_mode`，并由 `u_regs` 输出驱动

说明：

- 当前 Q8.8 主线核心不消费该位，但寄存器语义已就绪，可作为 BF16/FP16 顶层化的控制平面预留。

### 6.2 新增 FP16 转换模块单测

新增目录与测试：

- `experiments/bf16/fa_fp16_to_fp32/base/sources.f`
- `experiments/bf16/fa_fp16_to_fp32/tb/test_fa_fp16_to_fp32.py`
- `experiments/bf16/fa_fp32_to_fp16/base/sources.f`
- `experiments/bf16/fa_fp32_to_fp16/tb/test_fa_fp32_to_fp16.py`

执行：

```bash
make -C experiments verif MOD=bf16/fa_fp16_to_fp32 EXP=base
make -C experiments verif MOD=bf16/fa_fp32_to_fp16 EXP=base
```

结果：

- `fp16_to_fp32`: `samples=5000`, `mismatches=0`
- `fp32_to_fp16`: `samples=5000`, `mismatches=0`

### 6.3 顶层寄存器回归

执行：

```bash
make test MODULE=fa_attention_ip_top
```

结果：

- `test_reg_rw_and_start_busy`: PASS
- `test_reg_map_defaults_and_permissions`: PASS
- `test_register_dataflow_precision_and_cycles`: PASS
- `test_perf_counters_full_run`: PASS

并且主线性能口径保持：`cycles=85928`。

### 6.4 完成状态

到本报告为止，用户要求的追加项已全部完成：

1. `precision_mode` 顶层寄存器可配置：完成；
2. FP16 转换模块单测：完成；
3. 完整工作文档：完成（本文件）。