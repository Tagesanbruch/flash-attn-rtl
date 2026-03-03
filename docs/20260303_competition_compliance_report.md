# 20260303 FlashAttention 赛题符合性评估报告（当前工程）

## 1. 评估范围与结论摘要

本报告针对当前工程（RTL + cocotb + Python）逐条对照 [problem.md](../problem.md) 的 Baseline 必选要求进行评估，结论分为：

- **满足（Pass）**：已有实现且有测试证据。
- **部分满足（Partial）**：有局部实现，但未达到赛题端到端要求。
- **未满足（Fail）**：当前版本缺失该项关键能力。
- **未评估（N/A）**：当前工程尚不具备评估前提。

**总体结论（当前版本）**：

- 模块级基础算子、online softmax 子路径、AXI-Lite 控制寄存器路径具备可运行基础；
- 但仍是“Baseline 早期骨架”，尚未达到赛题要求的完整端到端 FlashAttention IP（缺失 DMA 主接口、K/V tiling 数据通路、S=256,d=64 全流程 RTL 验证与性能/带宽统计）。

---

## 2. 测试与分析方法

### 2.1 动态验证（本次新增/执行）

1) RTL 静态检查
- 命令：`make lint`
- 结果：通过（mul/exp/recip/online softmax/row core/regs/top）

2) cocotb 模块回归
- 命令：`make regress`
- 结果：通过（`fa_mul_sat_q8_8`、`fa_exp_pwl_8seg_q1_15`、`fa_recip_nr_q16_16`、`fa_online_softmax_update`、`fa_attention_ip_top`）

3) 顶层寄存器规范测试（本次增强）
- 命令：`make test MODULE=fa_attention_ip_top`
- 结果：2/2 通过
- 覆盖：默认值、R/W 生效、STATUS.DONE W1C、CYCLES 只读、START/BUSY/DONE 流程

4) 算法一致性审计（严格 online softmax 对照）
- 命令：`make audit-algo`
- 数据输出：[report/data/20260303_algorithm_audit.csv](data/20260303_algorithm_audit.csv)
- 用途：验证“online 递推 vs 直接 softmax”数值等价与 causal row0 角落行为

5) 与 PyTorch 对比（误差门限）
- 命令：
  - `make compare-torch`（S=64）
  - `python dv/python/torch_compare.py --s 256 --d 64 --causal --n-seeds 5 --seed 20260303 --csv-out report/data/20260303_torch_compare_s256d64.csv`
- 数据输出：[report/data/20260303_torch_compare_s256d64.csv](data/20260303_torch_compare_s256d64.csv)

### 2.2 静态结构审查

- 逐文件审查 `rtl/top`、`rtl/core`、`rtl/softmax`、`rtl/bus`；
- 重点检查：AXI4 Master/DMA 端口、tiling 相关状态机/缓冲、SxS 显式存储、寄存器映射与语义。

---

## 3. 赛题逐条符合性评估

## 3.1 基本功能要求（2.1）

### (1) SDPA 计算目标
- 结论：**Partial**
- 证据：
  - 已有 `fa_online_softmax_update` 与 `fa_row_reduction_core`（单行/单值路径）。
  - 顶层 [rtl/top/fa_attention_ip_top.sv](../rtl/top/fa_attention_ip_top.sv) 目前只接 `fa_core_controller` + `fa_axi_lite_regs`，无完整 `QK^T -> softmax -> PV` 数据通路。
- 说明：算法路径在“模块级”有基础，但“顶层端到端 SDPA”尚未实现。

### (2) FlashAttention-style 计算约束

#### 2.1 禁止显式存储注意力矩阵
- 结论：**Pass（当前结构层面）/Partial（系统层面）**
- 证据：当前 RTL 未出现 SxS score/p 矩阵存储结构。
- 说明：由于完整数据通路未搭建，系统层面的“严格不落地 SxS”还需在完整实现后复验。

#### 2.2 必须使用 online softmax
- 结论：**Pass（模块级）**
- 证据：`fa_online_softmax_update` 采用 `m/l/acc` 递推。
- 递推伪代码（从 RTL 抽象）：

```text
m_new = max(m_reg, score)
l_new = l_reg * exp(m_reg - m_new) + exp(score - m_new)
acc_new = acc_reg * exp(m_reg - m_new) + exp(score - m_new) * value
```

该逻辑对应文件：[rtl/softmax/fa_online_softmax_update.sv](../rtl/softmax/fa_online_softmax_update.sv)

#### 2.3 必须分块（tiling）处理 K/V
- 结论：**Fail**
- 证据：当前工程未见 K/V tile 缓冲、tile 调度 FSM、DMA 分块搬运路径。
- 说明：此项是当前最大缺口之一。

### (3) 固定输入规模（S=256, d=64）
- 结论：**Partial**
- 证据：
  - Python 侧已按 S=256,d=64 做对比测试；
  - RTL 顶层尚无完整 Q/K/V 数据流与 shape 控制逻辑，无法声明“硬件端到端支持 S=256,d=64”。

### (4) 数据格式（Q8.8 / 累加位宽）
- 结论：**Partial**
- 证据：
  - 输入/输出算子大量使用 16-bit（Q8.8）与 32-bit 累加路径；
  - `fa_row_reduction_core` 中有 32-bit 中间乘累加。
- 缺口：
  - `Q·K` 点积主路径与位宽保护策略（题目建议高于 32-bit）尚未在完整数据通路中落地。

### (5) 接口要求（AXI4-Lite + AXI4 Master DMA）
- 结论：**Partial / Fail**
- 证据：
  - AXI4-Lite 控制接口已实现并验证；
  - 顶层未实现 AXI4 Master 读写通道，DMA 未接入。

### (6) 寄存器要求
- 结论：**Pass（当前列出的寄存器骨架）**
- 覆盖证据：
  - 文件：[rtl/bus/fa_axi_lite_regs.sv](../rtl/bus/fa_axi_lite_regs.sv)
  - 测试：[dv/cocotb/tests/test_fa_attention_ip_top_regs.py](../dv/cocotb/tests/test_fa_attention_ip_top_regs.py)
- 本次验证点：
  - CTRL/STATUS/CFG/Q/K/V/O 基址/STRIDE/NEG_LARGE/SCALE/CYCLES 地址映射；
  - DEFAULT 值检查（如 STRIDE=128、NEG_LARGE=0xFFFF8000、SCALE=32）；
  - START 启动、DONE sticky、STATUS.DONE W1C；
  - CYCLES 只读行为。

### (7) 存储与资源约束
- 结论：**Partial**
- 证据：
  - 当前未见 score/p 全矩阵缓存；
  - 但 tiling 机制和中间 buffer 预算尚未完整实现并量化。

### (8) 正确性验收（MAE<=0.03, MaxAE<=0.10）
- 结论：**Partial（软件模型满足，RTL 端到端未完成）**
- 证据：
  - S=256,d=64,causal, 5 seeds（见 CSV）：
    - worst MAE = 0.000264
    - worst MaxAE = 0.005044
  - 均显著优于门限。
- 重要说明：该结果来自 Python 参考实现 vs PyTorch，对应“算法模型正确性”，不是 RTL 顶层端到端误差。

### (9) 测试验证要求
- 结论：**Partial**
- 已满足：
  - AXI-Lite 寄存器读写与启动完成流程（已测）
  - causal corner（算法审计中 row0 偏差=0）
- 未满足：
  - 随机 Q/K/V 的 RTL 端到端验证（受制于 DMA+数据通路未完成）

---

## 4. 性能要求（2.2）评估

### (1) 主频目标
- 结论：**N/A（顶层未完成）**
- 现状：仅有部分单模块 STA/综合结果，不能代表完整 attention IP 频率。

### (2) 面积约束 ≤ 200 万门
- 结论：**N/A（顶层未完成）**
- 现状：已有子模块估计（例如 `fa_core_controller` 的局部综合面积），但无 top 级统一门数折算。

### (3) 延迟 < 300k cycles
- 结论：**N/A（顶层未完成）**
- 说明：当前 `fa_core_controller` 的 `MAX_SIM_CYCLES=128` 是占位控制，不是真实 attention latency 指标。

### (4) 带宽统计 RD_BYTES/WR_BYTES
- 结论：**Fail（当前未实现）**
- 说明：DMA 未接入，当前无法输出有效 RD/WR 统计。

---

## 5. 算法与架构专项分析

## 5.1 online softmax 约束满足性

- 模块级实现清晰：`m/l/acc` 递推已在 RTL 明确编码；
- 严格算法审计（online exact vs direct softmax）显示最大偏差约 `4.77e-07`（数值等价成立）；
- causal corner 在审计中满足：`row0` 仅依赖 `j=0`（偏差为 0）。

## 5.2 tiling K/V 在 RTL 的体现

- 当前结论：**尚未体现**。
- 未见：
  - tile 尺寸配置寄存器或内部参数；
  - K/V tile SRAM/缓冲；
  - tile 级循环控制与 DMA burst 编排。

## 5.3 误差来源分析（当前可观测）

当前误差主要来自：
1) Q/K/V 量化到 Q8.8（输入离散化）
2) 定点乘加舍入与饱和
3) （未来）若接入 exp/recip 近似硬件，会引入额外近似误差

当前 S256 数据（5 seeds）显示误差远低于赛题门限，但这仍是“模型级”结论，需在完整 RTL 流水线上复验一次。

---

## 6. 资源与存储指标（当前阶段）

- 当前可提供：
  - 子模块综合/STA样本（非 top）
  - 算法级误差与稳定性数据
- 当前缺失：
  - top 级面积、时序、功耗
  - 带宽统计（RD_BYTES/WR_BYTES）
  - 片上中间 buffer 实际占用明细（需 tiling + DMA 完成后统计）

---

## 7. 可用于绘图的数据与建议图表

已生成数据：

1) 算法一致性审计（strict online vs direct）
- 文件：[report/data/20260303_algorithm_audit.csv](data/20260303_algorithm_audit.csv)
- 推荐图：
  - 图A：不同 S 下 `online_vs_direct_maxe` 箱线图
  - 图B：`causal_row0_deviation` 柱状图

2) 与 PyTorch 对比（S256,d64,causal,5 seeds）
- 文件：[report/data/20260303_torch_compare_s256d64.csv](data/20260303_torch_compare_s256d64.csv)
- 推荐图：
  - 图C：`mae/maxe/rmse` 多seed散点图
  - 图D：P95/P99 误差条形图

建议后续补充数据：
- DMA 打通后输出 `RD_BYTES/WR_BYTES`，用于图E（带宽分解图）
- top 级 STA 后输出 WNS/TNS/Fmax，用于图F（时序收敛图）
- top 级面积报告，图G（面积构成饼图/柱图）

---

## 8. 图注占位（仅占位，不含图片）

- 图1（架构总览）：FlashAttention IP 当前 RTL 架构与数据路径（控制/计算/存储）
- 图2（online softmax 数据流）：m/l/acc 递推与数值路径
- 图3（寄存器与控制时序）：START/BUSY/DONE/W1C 状态转移
- 图4（误差统计）：S=256,d=64 多 seed MAE/MaxAE/RMSE
- 图5（严格算法一致性）：online exact vs direct softmax 误差对比
- 图6（后续补充）：DMA 带宽读写统计（RD/WR bytes）
- 图7（后续补充）：top 级 STA/Fmax 与面积结果

---

## 9. 测试全流程与当前满足度总结

按赛题“必须项”视角：

- **已具备可验基础**：
  - AXI-Lite 控制寄存器功能
  - online softmax 模块化实现
  - 模块级定点算子验证
  - 算法模型误差门限明显达标

- **仍需完成的关键闭环**：
  1) AXI4 Master + DMA 数据搬运
  2) K/V tiling 数据通路
  3) S=256,d=64 RTL 端到端 attention 输出
  4) top 级正确性误差门限验证
  5) top 级 PPA（时序/面积/功耗）
  6) 带宽统计与优化分析

结论：当前版本可视为“可验证的 Baseline 前中期版本”，尚未达到赛题最终交付的完整闭环。