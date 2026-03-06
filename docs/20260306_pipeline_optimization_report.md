# FlashAttention 模块流水线优化实验报告

**日期**: 2026-03-06  
**PDK**: icsprout55 (ics55_LLSC_H7CL, tt/1.2V/25°C)  
**工具链**: Yosys (综合) + iEDA (STA)  
**目标频率**: 500 MHz (时钟周期 2.0 ns)

---

## 1. 实验概览

基于 exp_a 的 STA 基线结果（NR 倒数 201 MHz, 行归约核 178 MHz），开展了 3 组优化实验，通过流水线拆分和乘法器分解逐步逼近 500 MHz。

| 实验 | 模块 | 策略 | 流水级数 | Fmax (MHz) | WNS (ns) | TNS | 面积 (µm²) |
|:-----|:-----|:-----|:---------|:-----------|:---------|:----|:-----------|
| exp_a (基线) | fa_recip_nr_q16_16 | 3 级, 2 个 32×32 乘法/级 | 4 | 201 | -2.978 | -373.8 | 57,898 |
| **exp_b** | fa_recip_nr_q16_16 | 5 级, 1 个 32×32 乘法/级 | 5 | **324** | -1.090 | -203.7 | 57,333 |
| **exp_c** | fa_recip_nr_q16_16 | 10 级, 16×16 部分积流水 | 10 | **527 ✓** | **+0.102** | **0.000** | 60,594 |
| exp_a (基线) | fa_row_reduction_core | 3 级 NR | — | 178 | -3.611 | -873.2 | 90,023 |
| **exp_b** | fa_row_reduction_core | 集成 10 级 NR | — | **189** | -3.294 | -932.9 | 89,867 |

> ✓ = 时序收敛于 500 MHz，所有路径正 slack

---

## 2. fa_recip_nr_q16_16 优化历程

### 2.1 exp_b: 乘法级间拆分 (201 → 324 MHz, +61%)

**问题分析**: exp_a 的 Stage 2 在单个时钟周期内执行了两个串行 32×32 乘法:
```
dr0 = d_norm × r0           // 乘法 1 (~2.5ns)
corr = 2.0 - dr0            // 减法   (~0.3ns)
r1   = r0 × corr            // 乘法 2 (~2.5ns)
// 总计: ~5.3ns → WNS = -2.978ns
```

**优化方案**: 每级最多放置一个 32×32 乘法:
- Stage 1: CLZ + 32 项中点 LUT
- Stage 2: `dr0 = d_norm × r0` (仅乘法)
- Stage 3: 提取 dr0, 计算 `corr1 = 2 - dr0`, 计算 `r1 = r0 × corr1` (减法+乘法)
- Stage 4: `dr1 = d_norm × r1` (仅乘法)
- Stage 5: 提取、校正、反归一化

**结果**: 关键路径从双乘法的 4.92ns 降至 Stage 5 的 3.01ns (减法+乘法+移位)。但 32×32 乘法在该 PDK 下约 2.5ns，仍超过 2ns 预算。

### 2.2 exp_c: 16×16 部分积流水 (324 → 527 MHz, +63%)

**问题分析**: exp_b 的所有含乘法 stage 均 >2ns, 32×32 单个乘法器 ≈2.5ns 是根本瓶颈。

**优化方案**: 将每个 32×32 乘法分解为两级流水:
- **Sub-stage A**: 四个并行 16×16 部分积 (`a_hi×b_hi, a_hi×b_lo, a_lo×b_hi, a_lo×b_lo`, ~1.2ns)
- **Sub-stage B**: 移位累加四个部分积 → 64 位完整乘积 (~1.0ns)

此外，将 Stage 0 (CLZ + 移位) 与 Stage 1 (LUT 查表) 拆分为两级，消除 CLZ+LUT 串联的 2.07ns 关键路径。

**最终流水线 (10 级)**:
| 级 | 操作 | 估算延迟 |
|:---|:-----|:---------|
| S0 | CLZ(32) + barrel shift | ~1.5ns |
| S1 | 32 项 LUT case mux | ~0.5ns |
| S2 | d×r0 四个 16×16 部分积 | ~1.2ns |
| S3 | 累加 + 提取 + corr1 减法 | ~1.3ns |
| S4 | r0×corr1 四个 16×16 部分积 | ~1.2ns |
| S5 | 累加 + 提取 r1 | ~1.0ns |
| S6 | d×r1 四个 16×16 部分积 | ~1.2ns |
| S7 | 累加 + 提取 + corr2 减法 | ~1.3ns |
| S8 | r1×corr2 四个 16×16 部分积 | ~1.2ns |
| S9 | 累加 + 提取 r2 + 反归一化 | ~1.5ns |

**STA 结果**:
- WNS = **+0.102ns** (正 slack, 时序满足)
- 最慢路径: `s0_d_norm` (CLZ + barrel shift) = 1.85ns
- 面积: 60,594 µm² (相比 exp_a 仅增 +4.7%)
- 功能验证: 3/3 测试全通过, tolerance ≤ 2 LSB

---

## 3. fa_row_reduction_core 集成优化

### 3.1 exp_b: 集成 10 级 NR

将 exp_c 的 NR 倒数模块集成到 row_reduction_core, 同步更新:
- `acc_delay` 延迟线从 3 级扩展到 10 级
- NR 子模块时序已在 500 MHz 下收敛

**STA 结果**: WNS = -3.294ns, Fmax ≈ 189 MHz

### 3.2 瓶颈分析: 在线 Softmax 的反馈回路

关键路径 (`acc_q16_16`, `l_q16_16` 寄存器) 位于 `fa_online_softmax_update` 模块, 与 NR 子模块无关:

```
m_reg → comparator+mux → m_new            (~0.5ns)
     → subtract → diff_old                (~0.3ns)
     → exp_pwl_8seg (含 9×8 乘法)           (~2.0ns)
     → l_reg × exp_old (32×16 乘法)         (~2.0ns)
     → bit extract + add → l_new           (~0.3ns)
─────────────────────────────────────────── ~5.1ns
```

这是一个**数据反馈回路** (recurrence): `l_reg[n+1] = f(l_reg[n], score[n])`。每个时钟周期必须完成完整的 读→计算→写 循环, 无法通过流水线拆分优化, 除非接受**吞吐量减半** (每 2 个周期处理 1 个元素)。

**吞吐量分析**: 对于 Br=64 的典型行长度:
- 当前 (1 元素/周期, 178 MHz): 64 × 5.6ns = 358ns/行
- 若流水化 (1 元素/2 周期, 500 MHz): 128 × 2.0ns = 256ns/行 (提升 28%)
- 若降频不流水 (1 元素/周期, 300 MHz): 64 × 3.3ns = 213ns/行 (**最快**)

结论: 对于当前行长度, 提高 softmax 频率的收益有限。最佳策略是**整体设计运行在 softmax 支持的最高频率** (约 200 MHz), 或采用**多通道并行化**架构提升系统吞吐。

---

## 4. 面积影响

| 模块 | exp_a | exp_b | exp_c | 增幅 (exp_c/exp_a) |
|:-----|:------|:------|:------|:-------------------|
| fa_recip_nr_q16_16 | 57,898 | 57,333 | 60,594 | +4.7% |
| fa_row_reduction_core | 90,023 | 89,867 | — | -0.2% |

面积开销极小。10 级流水增加了寄存器, 但 16×16 部分积乘法器面积与 32×32 相当 (4 个 16×16 ≈ 1 个 32×32), Yosys 综合优化后面积几乎不变。

---

## 5. 文件清单

### fa_recip_nr_q16_16 实验
| 文件 | 说明 |
|:-----|:-----|
| `experiments/fa_recip_nr_q16_16/exp_b/fa_recip_nr_q16_16.sv` | 5 级流水 NR (324 MHz) |
| `experiments/fa_recip_nr_q16_16/exp_c/fa_recip_nr_q16_16.sv` | **10 级流水 NR (527 MHz, 500 MHz 收敛)** |
| `experiments/fa_recip_nr_q16_16/tb/test_fa_recip_nr_q16_16.py` | 共享测试 (updated: pipeline_depth=15, drain=20) |

### fa_row_reduction_core 实验
| 文件 | 说明 |
|:-----|:-----|
| `experiments/fa_row_reduction_core/exp_b/fa_row_reduction_core.sv` | 集成 10 级 NR, 10 级 acc_delay |
| `experiments/fa_row_reduction_core/exp_b/fa_recip_nr_q16_16.sv` | 10 级流水 NR (拷贝自 exp_c) |
| `experiments/fa_row_reduction_core/exp_b/fa_online_softmax_update.sv` | 在线 softmax (同 exp_a) |
| `experiments/fa_row_reduction_core/exp_b/fa_exp_pwl_8seg_q1_15.sv` | 8 段 PWL exp (同 exp_a) |

### STA 结果
| 目录 | 内容 |
|:-----|:-----|
| `syn/exp_fa_recip_nr_q16_16_exp_b_20260306/` | exp_b NR STA (324 MHz) |
| `syn/exp_fa_recip_nr_q16_16_exp_c_20260306/` | exp_c NR STA (**527 MHz ✓**) |
| `syn/exp_fa_row_reduction_core_exp_b_20260306/` | exp_b 集成 STA (189 MHz) |

---

## 6. 结论与下一步建议

### 已达成
1. **fa_recip_nr_q16_16 模块在 500 MHz 下时序收敛** (WNS=+0.102ns, Fmax=527 MHz)
2. 功能精度保持不变 (tolerance ≤ 2 LSB, 3/3 测试通过)
3. 面积增幅仅 4.7%

### 瓶颈
- `fa_online_softmax_update` 的数据反馈回路将 `fa_row_reduction_core` 整体 Fmax 限制在约 190 MHz

### 建议
1. **多通道并行**: 实例化多个 row_reduction_core 并行处理不同注意力头, 以 190 MHz × N 通道实现系统吞吐
2. **双周期 softmax**: 将 softmax 更新拆分为 2 周期 (exp 计算 + 乘法累加), 可达 ~350 MHz 但吞吐减半
3. **近似优化**: 用直接 LUT (无插值乘法) 替代 PWL exp, 减少关键路径约 0.8ns
4. **FPGA 目标**: 若目标为 FPGA, 可利用 DSP slice 实现流水化乘法, 关键路径将大幅缩短
