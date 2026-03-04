# FlashAttention IP 实现与验证报告

**日期**: 2026-03-03  
**工具链**: SystemVerilog + cocotb 1.9.2 + Verilator 5.034  
**赛题**: 基于大模型推理的 FlashAttention 高性能硬件加速器 IP 设计

---

## 1. 项目概述

本项目实现了一个可综合的 FlashAttention-style 注意力算子硬件 IP，覆盖赛题全部必选要求：

- **Online softmax** — 在线计算 m/l/acc，无需存储 S×S 注意力矩阵
- **K/V tiling** — Q 外循环 + K/V 内循环的双层 tile 调度
- **定点 Q8.8** — 输入/输出 16-bit 有符号定点，内部 40-bit 累加器
- **AXI4-Lite + AXI4 Master DMA** — 主机寄存器配置 + 加速器主动搬运数据
- **赛题寄存器映射** — CTRL/STATUS/CFG/Q_BASE/.../CYCLES 完整实现

---

## 2. 系统架构

### 2.1 顶层模块层次

```
fa_attention_ip_top (172 行)
├── fa_axi_lite_regs     (216 行) — AXI4-Lite 寄存器文件
├── fa_dma_reader        (116 行) — AXI4 Master 读 DMA
├── fa_dma_writer        (139 行) — AXI4 Master 写 DMA
└── fa_attention_core    (515 行) — 核心计算引擎
    ├── fa_mul_sat_q8_8     (27 行) — Q8.8 饱和乘法器
    ├── fa_exp_pwl_8seg_q1_15 (59 行) — 8 段 PWL exp 近似
    └── fa_recip_nr_q16_16  (22 行) — Newton-Raphson 倒数
```

### 2.2 参数配置

| 参数 | 赛题值 | 说明 |
|------|--------|------|
| SEQ_LEN | 256 | 序列长度 S |
| D | 64 | Head 维度 |
| TQ | 32 | Q tile 行数 |
| TK | 64 | K/V tile 行数 |
| BUS_W | 128 | AXI 数据总线宽度 (bits) |
| NUM_Q_TILES | 8 | S / TQ |
| NUM_K_TILES | 4 | S / TK |
| ELEMS_PER_BEAT | 8 | 每 AXI beat 传输的 Q8.8 元素数 |

### 2.3 双层 FSM 架构

**Master FSM** (10 状态):
```
S_IDLE → S_LOAD_Q → S_INIT_CONTEXT → S_LOAD_K → S_LOAD_V
       → S_COMPUTE → S_NEXT_K → S_NORMALIZE → S_WRITE_O
       → S_NEXT_Q → S_DONE
```

**Inner Compute FSM** (7 状态):
```
C_IDLE → C_DP_INIT → C_DP_RUN → C_SCORE_DONE
       → C_SOFTMAX_PREP → C_NEXT_KJ → C_NEXT_QI → C_DONE
```

### 2.4 数据流

1. **Load Q tile**: DMA 读取 TQ×D = 32×64 = 2048 个 Q8.8 元素 (256 AXI beats)
2. **Init context**: 初始化 row_m[], row_l[], row_acc[][] 
3. **For each K/V tile**:
   - DMA 读取 K tile (TK×D = 64×64, 512 beats)
   - DMA 读取 V tile (同上)
   - 串行计算 QK^T + online softmax + PV 累加
4. **Normalize**: row_acc / row_l → O tile
5. **Write O tile**: DMA 写回 TQ×D 结果

---

## 3. RTL 模块清单

### 3.1 核心计算模块

| 模块 | 行数 | 功能 |
|------|------|------|
| `fa_attention_core` | 515 | 主控 + 计算引擎，含双 FSM、q/k/v_buf、online softmax |
| `fa_dot_product_d` | 56 | 串行点积，D 元素/cycle，40-bit 累加器 |
| `fa_tile_buffer` | 80 | Ping-pong 双缓冲 tile SRAM |
| `fa_tile_compute_engine` | 249 | Tile 级计算 FSM (备选模块) |
| `fa_row_context_rf` | 70 | 行级 m/l/acc 寄存器堆 |
| `fa_row_reduction_core` | 61 | 行级 online softmax + norm |

### 3.2 算术原语

| 模块 | 行数 | 功能 | 精度 |
|------|------|------|------|
| `fa_mul_sat_q8_8` | 27 | Q8.8 饱和乘法 | 精确 + 饱和 |
| `fa_exp_pwl_8seg_q1_15` | 59 | 8 段线性近似 exp(x) | Q1.15 输出，MAE < 0.005 |
| `fa_recip_nr_q16_16` | 22 | Newton-Raphson 1/x | Q16.16，4 次迭代 |
| `fa_online_softmax_update` | 98 | Online softmax 状态更新 | m/l/acc 更新逻辑 |

### 3.3 总线接口

| 模块 | 行数 | 功能 |
|------|------|------|
| `fa_axi_lite_regs` | 216 | AXI4-Lite 寄存器映射 (17 个寄存器) |
| `fa_dma_reader` | 116 | AXI4 Master 读 DMA，AR/R 通道 |
| `fa_dma_writer` | 139 | AXI4 Master 写 DMA，AW/W/B 通道 |

### 3.4 代码统计

- **RTL 总行数**: ~1,970 行 SystemVerilog (活跃模块)
- **测试总行数**: ~1,512 行 Python (cocotb)
- **总模块数**: 13 个 SV 模块

---

## 4. 寄存器映射 (赛题完全对齐)

| Offset | 名称 | 访问 | 默认值 | 验证状态 |
|--------|------|------|--------|----------|
| 0x00 | CTRL | R/W | 0x0 | ✅ start/reset/irq_en |
| 0x04 | STATUS | R (W1C) | 0x0 | ✅ busy/done/error |
| 0x08 | CFG | R/W | 0x0 | ✅ causal_en |
| 0x14 | Q_BASE_L | R/W | 0x0 | ✅ |
| 0x18 | Q_BASE_H | R/W | 0x0 | ✅ |
| 0x1C | K_BASE_L | R/W | 0x0 | ✅ |
| 0x20 | K_BASE_H | R/W | 0x0 | ✅ |
| 0x24 | V_BASE_L | R/W | 0x0 | ✅ |
| 0x28 | V_BASE_H | R/W | 0x0 | ✅ |
| 0x2C | O_BASE_L | R/W | 0x0 | ✅ |
| 0x30 | O_BASE_H | R/W | 0x0 | ✅ |
| 0x34 | STRIDE_BYTES | R/W | 0x80 | ✅ d×2=128 |
| 0x38 | NEG_LARGE | R/W | 0xFFFF8000 | ✅ |
| 0x3C | SCALE | R/W | 0x20 | ✅ 1/√64≈0.125 |
| 0x40 | CYCLES | R | 0x0 | ✅ 只读 |

---

## 5. 验证结果

### 5.1 测试总览

| 模块 | 测试数 | 状态 | 说明 |
|------|--------|------|------|
| fa_mul_sat_q8_8 | 2 | ✅ PASS | 有向 + 随机 |
| fa_exp_pwl_8seg_q1_15 | 2 | ✅ PASS | 有向 + 单调性/误差 |
| fa_recip_nr_q16_16 | 2 | ✅ PASS | 有向 + 随机 |
| fa_online_softmax_update | 1 | ✅ PASS | 行级状态更新 |
| fa_dma_reader | 4 | ✅ PASS | 突发/错误/字节计数/背靠背 |
| fa_dma_writer | 3 | ✅ PASS | 突发/错误/字节计数 |
| fa_tile_buffer | 2 | ✅ PASS | 填充读取 + 交换独立性 |
| fa_dot_product_d | 5 | ✅ PASS | 零/恒等/已知/随机/连续 |
| fa_attention_core (小参数) | 1 | ✅ PASS | S=32,D=8 端到端 |
| fa_attention_core (赛题参数) | 1 | ✅ PASS | S=256,D=64 端到端 |
| fa_attention_ip_top | 2 | ✅ PASS | 寄存器 R/W + BUSY |
| **合计** | **25** | **25 PASS** | |

### 5.2 端到端正确性 (赛题参数 S=256, D=64)

| 指标 | 赛题要求 | 实测值 | 通过 |
|------|----------|--------|------|
| MAX_AE (定点同构参考) | — | **0** | ✅ |
| MAE (定点同构参考) | — | **0.00** | ✅ |
| MAX_AE (独立 C++ FP32 参考) | ≤ 0.10 | **4.054396** | ❌ |
| MAE (独立 C++ FP32 参考) | ≤ 0.03 | **1.009794** | ❌ |

> 注1: “定点同构参考”使用与 RTL 同一套定点算术路径，仅用于检查 RTL 功能一致性。
> 注2: 本次新增独立 C++ SDPA（浮点）对照后，确认当前实现尚未满足 FP32 门限。

### 5.3 性能指标

| 指标 | 赛题要求 | 实测值 | 说明 |
|------|----------|--------|------|
| 执行周期数 | < 300k cycles | **4,511,050 cycles** | ❌ 超标（串行架构） |
| 仿真时间 | — | 110 秒 | Verilator wall time |

**性能差距分析**:
当前实现为完全串行架构 — 每个点积 D cycles（1 元素/cycle），每个 (qi, kj) 对依次计算。
总计算量 ≈ NUM_Q_TILES × NUM_K_TILES × TQ × TK × (D + overhead) = 8 × 4 × 32 × 64 × 67 ≈ 4.4M cycles。

**优化路径** (后续迭代):
1. **点积并行化**: 8 路 MAC 阵列 → D/8 = 8 cycles/dot → 性能 ×8
2. **行级流水线**: 多行同时处理 → 隐藏 softmax 延迟
3. **DMA/Compute 重叠**: 预取下一个 K/V tile 同时计算当前 tile
4. 目标: 8 路并行 + double-buffer 预取 → ~300k–500k cycles

---

## 6. 赛题合规检查

| 要求 | 状态 | 说明 |
|------|------|------|
| FlashAttention-style (online softmax) | ✅ | fa_attention_core 内置 online softmax 逻辑 |
| K/V tiling | ✅ | TK=64, NUM_K_TILES=4 的内循环 |
| 禁止显式存储 S×S 注意力矩阵 | ✅ | 仅存 q_buf[TQ][D], k_buf[TK][D], v_buf[TK][D] |
| 定点 Q8.8 I/O | ✅ | 16-bit signed I/O, 40-bit 内部累加 |
| Dot-product 累加 ≥ 32-bit | ✅ | 40-bit (logic signed [39:0]) |
| AXI4-Lite 控制接口 | ✅ | 完整寄存器映射 |
| AXI4 Master DMA 数据接口 | ✅ | 读/写 DMA 引擎 |
| 寄存器映射对齐 | ✅ | 0x00–0x40 全部实现 |
| Causal mask 支持 | ⚠️ | 代码已实现，未独立验证 |
| cocotb 验证 | ✅ | 25 个测试全部通过 |
| S=256, D=64 端到端（定点同构） | ✅ | MAX_AE=0, MAE=0.00 |
| S=256, D=64 对 FP32 门限 | ❌ | MAE=1.009794, MAX_AE=4.054396 |
| 周期数 < 300k | ❌ | 4.5M (需并行优化) |

---

## 7. 片上存储分析

### 7.1 Buffer 用量

| Buffer | 大小 | 位宽 | 总 bits | 说明 |
|--------|------|------|---------|------|
| q_buf | TQ × D = 2048 | 16-bit | 32,768 | Q tile 本地缓存 |
| k_buf | TK × D = 4096 | 16-bit | 65,536 | K tile 本地缓存 |
| v_buf | TK × D = 4096 | 16-bit | 65,536 | V tile 本地缓存 |
| o_buf | TQ × D = 2048 | 16-bit | 32,768 | O tile 输出缓存 |
| row_m | TQ = 32 | 16-bit | 512 | 行最大值 |
| row_l | TQ = 32 | 32-bit | 1,024 | 行累加和 |
| row_acc | TQ × D = 2048 | 32-bit | 65,536 | 行加权累加 |
| **合计** | | | **263,680 bits** | ≈ 32 KB |

### 7.2 带宽分析

| 操作 | 次数 | Beats/次 | 总 Beats | 总字节 |
|------|------|----------|----------|--------|
| Load Q tile | 8 | 256 | 2,048 | 32,768 |
| Load K tile | 32 | 512 | 16,384 | 262,144 |
| Load V tile | 32 | 512 | 16,384 | 262,144 |
| Write O tile | 8 | 256 | 2,048 | 32,768 |
| **合计** | | | **36,864** | **589,824 B** ≈ 576 KB |

---

## 8. 文件清单

### 8.1 RTL

```
rtl/
├── bus/
│   ├── fa_axi_lite_regs.sv        # AXI4-Lite 寄存器映射
│   ├── fa_dma_reader.sv           # AXI4 Master 读 DMA
│   └── fa_dma_writer.sv           # AXI4 Master 写 DMA
├── common/
│   ├── fa_clip_signed.sv          # 饱和截断
│   ├── fa_fixed_point_pkg.sv      # 定点常量包
│   └── fa_mul_sat_q8_8.sv         # Q8.8 饱和乘法
├── core/
│   ├── fa_attention_core.sv       # ★ 主计算核心 (515 行)
│   ├── fa_dot_product_d.sv        # 串行点积
│   ├── fa_row_context_rf.sv       # 行上下文寄存器
│   ├── fa_tile_buffer.sv          # Ping-pong 缓冲
│   ├── fa_tile_compute_engine.sv  # Tile 计算 FSM (备选)
│   └── fa_row_reduction_core.sv   # 行 reduction (备选)
├── softmax/
│   ├── fa_exp_pwl_8seg_q1_15.sv   # PWL exp 近似
│   ├── fa_online_softmax_update.sv # Online softmax 更新
│   └── fa_recip_nr_q16_16.sv      # NR 倒数
└── top/
    └── fa_attention_ip_top.sv     # 顶层集成
```

### 8.2 验证

```
dv/cocotb/
├── common.mk                      # 构建系统 (模块选择 + 参数)
├── Makefile                        # 入口 (test/regress/lint)
├── tests/
│   ├── axilite_master.py           # AXI-Lite 主机驱动
│   ├── fp_ref.py                   # 定点运算 Python 参考
│   ├── test_fa_attention_core.py   # ★ 端到端系统测试 (323 行)
│   ├── test_fa_attention_ip_top_regs.py # 寄存器测试
│   ├── test_fa_dma_reader.py       # DMA 读测试
│   ├── test_fa_dma_writer.py       # DMA 写测试
│   ├── test_fa_dot_product_d.py    # 点积测试
│   ├── test_fa_exp_pwl_8seg_q1_15.py # exp 近似测试
│   ├── test_fa_mul_sat_q8_8.py     # 饱和乘法测试
│   ├── test_fa_online_softmax_update.py # softmax 更新测试
│   ├── test_fa_recip_nr_q16_16.py  # 倒数测试
│   └── test_fa_tile_buffer.py      # tile 缓冲测试
└── tb/
    └── filelist.mk                 # 源文件列表
```

---

## 9. 复现命令

```bash
# 环境要求
# - Verilator 5.034+
# - Python 3.13 + cocotb 1.9.2 (pip install cocotb==1.9.2)

# 激活虚拟环境
source .venv/bin/activate
cd dv/cocotb

# 全量回归 (小参数, ~2 秒)
make regress

# 单模块测试
make test MODULE=fa_attention_core           # 小参数 S=32,D=8
make test MODULE=fa_attention_core_full      # 赛题参数 S=256,D=64 (~110s)
make test MODULE=fa_dma_reader
make test MODULE=fa_dot_product_d

# Lint 检查
cd ../.. && make lint
```

---

## 10. 已知限制与后续计划

### 10.1 已知限制
1. **周期数超标**: 4.5M vs 300k 要求（串行点积，需并行化）
2. **Causal mask**: 代码已实现但缺少独立测试用例
3. **FP32 对比**: 当前 golden 使用定点参考，需增加 FP32 对比测试
4. **DMA burst 分拆**: 内部 cmd_len 已扩展为 16 位，DMA reader/writer 尚未实现自动 burst 分拆（> 256 beats 时需要）

### 10.2 优化计划
1. **并行 MAC 阵列**: 8 路并行点积 → 预计 ~560k cycles
2. **DMA 预取 pipeline**: K/V tile double-buffering，Compute 与 Load 重叠
3. **行级并行**: 多行同时处理，softmax update pipeline
4. **综合目标**: yosys → iEDA STA，目标 Fmax ≥ 200 MHz

---

*报告生成时间: 2026-03-03*
