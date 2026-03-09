# 2026-03-09 top/core/cmodel 误差口径对账与 cmodel RTL 等价更新

## 1. 结论摘要

本轮排查确认了三件事：

1. [docs/report_0306/03_验证结果与完整周期评估.md](docs/report_0306/03_%E9%AA%8C%E8%AF%81%E7%BB%93%E6%9E%9C%E4%B8%8E%E5%AE%8C%E6%95%B4%E5%91%A8%E6%9C%9F%E8%AF%84%E4%BC%B0.md#L144-L152) 中的
   - `RTL vs FP32 MAE = 0.00291701`
   - `RTL vs FP32 MAX_AE = 0.00588431`
   是 **core / Verilator C++ profile** 的口径，不是 `top` 的口径。
2. 之前 `top` 测试没有按同一口径做 `RTL vs FP32` 对比，因此不能直接把旧文档里的 `0.00291701` 套到 `top`。
3. `cmodel` 旧有模式与当前主线 RTL 已经不严格等价；本轮新增 `rtl_strict` 后，`cmodel` 已可作为**当前 RTL 算术等价参考**使用。

---

## 2. 误差口径为什么会混淆

### 2.1 历史文档中的口径

`rtl-latency-profile` 使用的是 [dv/verilator_cpp/fa_attention_core_tb.cpp](dv/verilator_cpp/fa_attention_core_tb.cpp)，其最终报告的是：

- `RTL vs FP32`
- 输出已换算到实数域
- 即赛题门限使用的口径

### 2.2 这轮 top 测试最初打印的口径

在 [dv/cocotb/tests/test_fa_attention_ip_top_regs.py](dv/cocotb/tests/test_fa_attention_ip_top_regs.py) 中，最初补的检查首先是：

- `RTL vs fixed-q8.8 reference`
- 误差单位是 Q8.8 LSB

因此最初看到的：

- `mae = 4.6394`

本质上是：

- `4.6394 LSB`
- 等价实数误差约为：

$$
4.6394 / 256 = 0.018123
$$

所以它并不是直接可与 `0.00291701` 做一一对比的同口径数值。

---

## 3. 本轮实际复测结果

## 3.1 core / profile 当前结果

重新执行 `make rtl-latency-profile` 后，当前 [docs/data/20260304_rtl_summary.csv](docs/data/20260304_rtl_summary.csv) 仍给出：

- `rtl_fp32_mae = 0.00291701`
- `rtl_fp32_maxae = 0.00588431`

这说明：

- 当前 `fa_attention_core` 主线算术本身没有被 perf counter 改坏；
- profile 历史结论仍成立。

## 3.2 core cocotb 对齐 profile stimulus 的结果

在 [dv/cocotb/tests/test_fa_attention_core.py](dv/cocotb/tests/test_fa_attention_core.py) 中补充了：

- 可配置 `seed`
- 可配置输入值范围
- 可配置 `causal`
- 同时打印 `RTL vs fixed-like` 与 `RTL vs FP32`

当对齐到 profile 风格输入：

- `seed = 2025`
- `range = [-32, 31]`
- `causal = 1`

得到：

- `RTL vs fixed-like: MAE = 0.6261 LSB, MAX_AE = 1 LSB`
- `RTL vs FP32: MAE = 0.002777, MAX_AE = 0.005881`

与 profile 的 `0.002917 / 0.005884` 高度一致。

## 3.3 top 对齐同一 stimulus 的结果

在 [dv/cocotb/tests/test_fa_attention_ip_top_regs.py](dv/cocotb/tests/test_fa_attention_ip_top_regs.py) 中补充了：

- 可配置 `seed`
- 可配置输入值范围
- 可配置 `scale_q8_8`
- 可配置 `neg_large_q8_8`
- 同时打印 `RTL vs fixed-q8.8` 与 `RTL vs FP32`

当对齐到：

- `seed = 2025`
- `range = [-32, 31]`
- `causal = 1`
- `neg_large_q8_8 = -2048`

得到：

- `RTL vs fixed-q8.8: mae_lsb = 2.8235`
- 即实数 `mae = 0.011029`
- `RTL vs FP32: mae = 0.011081`
- `RTL vs FP32: max_err = 0.234375`

这明显比 core 差。

### 当前判断

这说明：

- `core` 主算术路径仍然保持旧文档中的高精度；
- `top` 当前的数值表现更差；
- 差异不是由 perf counter 本身引起；
- 更可能来自 `top` 集成路径，特别是 `fa_dma_reader` 将 512-beat 逻辑读拆成多个合法 AXI burst 后，core 在真实 split-burst 数据时序下与 direct-core testbench 不完全等价。

### 后续补充：已完成根因定位与修复

在继续做 `top-like DMA` 复现实验后，已经把问题进一步收敛并修复：

1. 先在 standalone `fa_attention_core` cocotb 中分别引入 top-like `read` / `write` 时序；
2. 结果表明：
    - 仅 `read` 侧 top-like：精度仍与 direct-core 一致；
    - 仅 `write` 侧 top-like：可稳定复现与 `top` 完全一致的误差；
3. 因而最终根因定位到 `fa_attention_core` 的 `S_WRITE_O` 写出握手实现，而不是 `fa_dma_reader` 的 split-burst 逻辑。

具体根因为：

- 原实现里 `o_write_cnt` 仅按 `dma_wr_data_ready` 推进，而不是按真实握手 `dma_wr_data_valid && dma_wr_data_ready` 推进；
- 同时 `dma_wr_data` 使用时序寄存式逐拍更新；
- 当 top 中 `fa_dma_writer` 在 `AW` 之后才进入 `W_DATA`、产生真实 backpressure 时，写回 beat 会发生一拍错位。

修复方式：

- 在 [rtl/core/fa_attention_core.sv](rtl/core/fa_attention_core.sv) 中，把 `S_WRITE_O` 的 beat 推进条件改为 `valid && ready`；
- 将 `dma_wr_data / dma_wr_data_valid / dma_wr_data_last` 改为由当前 `o_write_cnt` 组合生成，保证当前拍输出和当前待发送 beat 严格对齐。

修复后复测结果：

- standalone core + top-like DMA：
   - `RTL vs FP32: MAE = 0.002777`
   - `MAX_AE = 0.005881`
- integrated top：
   - `RTL vs fixed-q8.8: MAE = 0.6261 LSB, MAX_AE = 1 LSB`
   - `RTL vs FP32: MAE = 0.002777, MAX_AE = 0.005881`

这说明 `top` 已重新对齐到 `core/profile` 精度水平。

---

## 4. DMA 侧补充排查

为排查 split-burst 读路径，本轮新增并通过了：

- [dv/cocotb/tests/test_fa_dma_reader.py](dv/cocotb/tests/test_fa_dma_reader.py)
  - `test_split_long_command`
  - `test_split_exact_512_command`

它们验证了：

- AR 地址连续性
- ARLEN 拆分正确性
- 跨 burst 数据连续性
- `out_last` 只在逻辑命令最终末拍拉高

因此当前可以说：

- `fa_dma_reader` 单模块的 burst split 逻辑本身是正确的；
- 历史上的 `top` 精度异常并不是读侧 split-burst 数据错误；
- 真正根因是 `core` 写出接口在真实 backpressure 下的握手实现；
- 该问题现已修复。

---

## 5. cmodel 更新：新增当前 RTL 严格等价模式

旧版 cmodel 中的 `rtl_exact / rtl_real_exp` 等模式，和当前主线 RTL 并不严格一致，主要差异包括：

- 累加位宽
- `PV` 项缩放
- normalize 路径
- reciprocal 的实现方式

本轮在：

- [cmodel/csrc/attention_core.hpp](cmodel/csrc/attention_core.hpp)
- [cmodel/csrc/attention_math.cpp](cmodel/csrc/attention_math.cpp)
- [cmodel/csrc/attention_kernels.cpp](cmodel/csrc/attention_kernels.cpp)
- [cmodel/csrc/attention_experiment.cpp](cmodel/csrc/attention_experiment.cpp)
- [cmodel/csrc/attention_lib.cpp](cmodel/csrc/attention_lib.cpp)

新增了 `rtl_strict` 模式，其特征为：

- `64-bit row_acc`
- 与 RTL 相同的 `q8_8_mul_sat`
- 与 RTL 相同的 `exp_pwl_q1_15`
- 端口级移植的 `fa_recip_nr_q16_16` 近似函数
- 与 RTL 相同的 `Q32.32` rounding / saturation normalize 路径

该模式用于近似“当前主线 RTL 算术行为”。

---

## 6. cmodel 新结果

### 6.1 单 seed（与 profile 对齐）

命令配置：

- `seed = 2025`
- `input_mode = small-int`
- `causal = 1`
- `neg_large_q8_8 = -8192`

`rtl_strict` 结果：

- `MAE = 0.002914`
- `MaxAE = 0.011719`

可见：

- `MAE` 已与 current profile/core 高度一致；
- `MaxAE` 略高于 profile 的 `0.00588431`，但仍显著优于门限 `0.10`。

### 6.2 五个 seed 的正式评估

输出 CSV：

- [docs/data/20260309_cmodel_rtl_strict_smallint_causal_neg32.csv](docs/data/20260309_cmodel_rtl_strict_smallint_causal_neg32.csv)

`rtl_strict` 汇总结果：

- `MAE(mean) = 0.002674`
- `MaxAE(worst) = 0.011719`

因此：

- `MAE <= 0.03`：PASS
- `MAX_AE <= 0.10`：PASS

---

## 7. 对“是否需要先在 cmodel 上优化再反推 RTL”的结论

当前不需要进入“先优化 cmodel 再反推 RTL”的阶段，原因是：

1. 新的 `rtl_strict` 已经满足赛题精度门限；
2. 它的 `MAE` 已基本对齐当前主线 `core/profile`；
3. 当前并不存在新的 core 算术风险点；此前 `top` 偏差已定位为写侧握手问题并修复。

也就是说：

- **cmodel 这一侧已恢复为可用、可信、且与当前 RTL 主算术基本对齐的对照模型；**
- **后续重点应放在保持接口级时序语义正确，而不是继续盲目优化 cmodel。**

---

## 8. 当前建议

下一步建议按这个顺序推进：

1. 保留 standalone `top-like DMA` 用例，作为接口时序回归基线
2. 在后续优化中继续优先检查 `valid/ready` 语义，而不是只看无 backpressure 的理想场景
3. 若后续修改 write path / DMA wrapper，重复执行 `core_toplike_dma + ip_top` 两级回归

当前不建议修改 [docs/report_0306/03_验证结果与完整周期评估.md](docs/report_0306/03_%E9%AA%8C%E8%AF%81%E7%BB%93%E6%9E%9C%E4%B8%8E%E5%AE%8C%E6%95%B4%E5%91%A8%E6%9C%9F%E8%AF%84%E4%BC%B0.md)，因为该文档描述的是当时 `core/profile` 口径下的结论，本身并不错误；应新增说明文档而不是覆盖历史结论。
