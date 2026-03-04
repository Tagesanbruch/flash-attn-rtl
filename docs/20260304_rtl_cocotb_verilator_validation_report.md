# 2026-03-04 RTL实现与验证报告（Verilator C++ TB + cocotb）

## 1. 目标与结论

本轮目标：
1. 将 cmodel 已验证的可行优化映射到 RTL（不走“仅模型层”结论）。
2. 用 `verilator cpp tb` 验证精度门限。
3. 完成 AXI-Lite 寄存器功能验证（尽可能充分）、数据流相关验证、`CYCLES` 读取验证。
4. 输出可复现实验与结论报告。

结论：
- **精度门限（与 FP32 golden）已通过**：
  - `MAE=0.000972`
  - `MAX_AE=0.002032`
- cocotb：
  - `fa_exp_pwl_8seg_q1_15` 通过
  - `fa_attention_core_full` 通过（Python fixed 参考 bit 对齐）
  - `fa_attention_ip_top` 寄存器套件通过（含 `CYCLES` 行为验证）
- `o_cycles` 在 C++ TB 中可读且与执行周期一致。

---

## 2. 关键澄清（acc 含义）

- `dot`：`Q·K` 点积累加（Dot-product 累加）
- `acc`：在线 softmax 后的值向量累加（`acc <- acc*exp_old + exp_new*V`）

本次 RTL 优化主要针对后者（`acc`），并同时优化 mask 尾部泄漏路径。

---

## 3. RTL改动摘要

### 3.1 `acc` 高精度定点路径（核心）
文件：`rtl/core/fa_attention_core.sv`

- `row_acc` 从 32-bit 扩展到 64-bit。
- 在线更新改为高精度形式：
  - `acc_old_sc = (row_acc * exp_old) >> 15`
  - `pv_term = (exp_new * V) << 1`
  - `row_acc = acc_old_sc + pv_term`
- 归一化改为“带符号四舍五入除法”：
  - `out = round(row_acc / row_l)` 后饱和到 Q8.8。

### 3.2 exp近似在尾部抑制泄漏
文件：`rtl/softmax/fa_exp_pwl_8seg_q1_15.sv`

- 输入 clamp 扩展到 `[-16, 0]`。
- 保留 `[0,8]` 区间原 8 段 PWL 精度。
- 对 `< -8` 区间直接输出 0（近似 `-inf`，抑制 causal neg-mask 泄漏）。

### 3.3 参考模型与验证链路同步
- `dv/verilator_cpp/fa_attention_core_tb.cpp`
  - 参考模型同步为高精度 acc 路径
  - causal 模式打开
  - `NEG_LARGE=-8192`（Q8.8 = -32）
  - 读取并打印 `o_cycles`
- `dv/cocotb/tests/fp_ref.py`
  - `exp_pwl_q1_15` 与 RTL 同步
  - `exp_real_q1_15` 截断到 `-16`
- `dv/cocotb/tests/test_fa_attention_core.py`
  - Python fixed 参考改为高精度 acc + rounded divide，与 RTL 对齐
- `dv/cocotb/tests/test_fa_attention_ip_top_regs.py`
  - 增强寄存器多值读写验证
  - 增加 `CYCLES` 行为验证（运行中增长、soft_reset 后仍可读）

---

## 4. 验证结果

### 4.1 Verilator C++ TB（核心门限）
命令：
```bash
make verilator-cpp-run
```

关键输出：
- `DONE cycles=4510976, o_cycles=4510976`
- `RTL vs FP32: MAE=0.000972, MAX_AE=0.002032`
- 门限检查：
  - `MAE<=0.03: PASS`
  - `MAX_AE<=0.10: PASS`

### 4.2 cocotb：exp 模块
命令：
```bash
make test MODULE=fa_exp_pwl_8seg_q1_15
```
结果：`PASS`（directed + monotonic/error）

### 4.3 cocotb：attention_core full
命令：
```bash
make test MODULE=fa_attention_core_full
```
结果：`PASS`
- `Core done after 4511050 cycles`
- `MAX_AE=0, MAE=0.00`（对齐 Python fixed 参考）

### 4.4 cocotb：attention_ip_top 寄存器
命令：
```bash
make test MODULE=fa_attention_ip_top
```
结果：`PASS`（3/3）
- `test_reg_rw_and_start_busy`
- `test_reg_map_defaults_and_permissions`
- `test_register_dataflow_precision_and_cycles`

---

## 5. 与赛题要求对照

### 已满足（本轮已验证）
1. 正确性门限（相对 FP32）：通过（见 Verilator C++ TB）。
2. 在线 softmax + 分块：RTL 结构保持。
3. 禁止显式存储 SxS 注意力矩阵：保持满足。
4. 寄存器功能验证：完成并增强。
5. `CYCLES` 可读与行为验证：完成（核心完成后读出、寄存器行为读出）。

### 当前风险/未满足项
- **延迟指标 `<300k cycles` 目前未满足**：
  - 当前核心执行约 `4.51M cycles`。
  - 本轮聚焦正确性/验证闭环与寄存器完备验证，未进行结构级吞吐优化。

---

## 6. 复现命令

```bash
# 1) 精度门限（关键）
make verilator-cpp-run

# 2) exp单元
make test MODULE=fa_exp_pwl_8seg_q1_15

# 3) core端到端（full参数）
make test MODULE=fa_attention_core_full

# 4) top寄存器套件（含CYCLES行为）
make test MODULE=fa_attention_ip_top
```

---

## 7. 备注

本轮“通过”定义聚焦于赛题正确性门限、寄存器功能与验证闭环；
若按比赛最终评审全量指标，还需继续针对 `cycles` 做架构级优化（并行度、流水深度、访存重叠、tile 数据复用等）。