# FlashAttention 单点 Attention IP 开发计划（FSA借鉴版，赛题合规）

## 1. 目标与定位

### 1.1 总体定位
- 本项目**不会直接提交 FSA 原工程**，而是借鉴其“执行计划 + 单阵列融合”思想，按赛题接口和数据格式重构为可综合 SystemVerilog IP。
- 主目标：先在本机完成 baseline（S=256,d=64,causal,Q8.8）可验证版本，再推进 yosys/iEDA STA。

### 1.2 基线策略
- 阵列规模优先采用 `16x16`（而不是 128x128）：
  - 满足本机仿真速度与开发节奏；
  - 通过 tile 调度覆盖 S=256,d=64；
  - 后续可参数化扩到 32x32/64x64。

### 1.3 范围边界
- 当前纳入：baseline 必选项（含 causal、online softmax、不存 SxS、AXI-Lite+DMA 模式）。
- 当前不纳入：bonus #9（DMA/任务队列）等可选项，后续作为**独立版本**开发，不影响 baseline。

---

## 2. FSA 借鉴映射（非直接复用）

### 2.1 借鉴内容
- `ExecutionPlan/ControlGen` 思想：将 `QK^T -> rowmax/exp/sum -> PV -> norm` 拆成可重叠时序阶段。
- `PE/CMP/Accumulator` 思想：非 matmul 操作进入阵列数据流，不依赖独立大向量核。
- `BankedSRAM + DMA` 思想：tile 双缓冲、读写重叠。

### 2.2 必须替换内容
- 数据通路：FP16/FP32 -> Q8.8 + 高位累加。
- 控制面：指令 FIFO/sem -> 赛题寄存器映射（CTRL/STATUS/CFG/BASE/STRIDE/...）。
- 工程依赖：chipyard/chisel -> 独立 SV + cocotb + Verilator。

---

## 3. 赛题约束落地

- 公式目标：`O = softmax(QK^T/sqrt(d)+M)V`。
- 强制要求：
  - online softmax；
  - K/V tiling；
  - 禁止显式存 score/prob 全矩阵；
  - causal mask 必须支持；
  - AXI4-Lite 控制 + AXI Master DMA 数据搬运。
- baseline 参数固定：`S=256,d=64,batch=1,head=1`。

---

## 4. 体系结构规划

## 4.1 顶层（L2）
- `fa_attention_ip_top.sv`
  - AXI4-Lite 从接口（寄存器）
  - DMA 主接口（后续逐步补齐）
  - 核心控制器/计算核

## 4.2 中层（L1）
- `fa_core_controller.sv`
  - tile 循环状态机：Q tile 外循环 + K/V tile 内循环
  - causal row/col 索引管理
  - m/l/acc 生命周期管理
- `fa_row_reduction_core.sv`
  - row 级 online softmax + norm

## 4.3 底层（L0）
- 算术原语：`fa_mul_sat_q8_8` / `fa_exp_pwl_8seg_q1_15` / `fa_recip_nr_q16_16`。
- 状态原语：`fa_online_softmax_update`。
- 后续新增：`fa_vec_dot_q8_8`、`fa_rowmax_reduce`、`fa_rowsum_reduce`。

---

## 5. 接口与寄存器计划（赛题对齐）

实现固定寄存器（至少）：
- `0x00 CTRL`：START/SOFT_RESET/IRQ_EN
- `0x04 STATUS`：BUSY/DONE(ERROR)
- `0x08 CFG`：CAUSAL_EN
- `0x14~0x30`：Q/K/V/O base addr（64b split）
- `0x34 STRIDE_BYTES`
- `0x38 NEG_LARGE`
- `0x3C SCALE`
- `0x40 CYCLES`

备注：当前先做 AXI-Lite 语义正确 + 核心握手正确，DMA master 逐步从 stub 到可跑。

---

## 6. 项目结构（更新）

```text
flashattn/
├── plan.md
├── rtl/
│   ├── common/
│   ├── softmax/
│   ├── core/
│   ├── bus/
│   │   └── fa_axi_lite_regs.sv
│   └── top/
│       └── fa_attention_ip_top.sv
├── dv/
│   ├── cocotb/
│   │   ├── tests/              # 模块级 + 顶层寄存器级
│   │   └── ...
│   └── python/
│       ├── ref_attention.py    # 定点 golden
│       └── torch_compare.py    # 与 torch 对比
├── python/
│   └── host_api/
│       └── fsa_like_api.py     # 借鉴FSA“高层API封装硬件细节”思想
├── cfg/
├── scripts/
├── report/
└── syn/
```

---

## 7. 验证策略（含 Torch 对比）

## 7.1 模块级
- 维持现有 cocotb 单模块回归。

## 7.2 子系统级
- 新增 `fa_attention_ip_top` 寄存器与启动流程测试：
  - AXI-Lite 写寄存器；
  - START -> BUSY -> DONE；
  - DONE 清零语义。

## 7.3 算法对比级（Python）
- `torch_compare.py`：
  - 用同一组 Q/K/V（float）
  - 走固定点量化/online softmax 参考实现
  - 对比 `torch.nn.functional.scaled_dot_product_attention`
  - 输出 MAE/MaxAE，用于逼近赛题误差门限。

## 7.4 API层（借鉴FSA）
- 不是复刻 FSA ISA，而是提供“类型安全的 host API”封装：
  - 自动检查 shape/stride/dtype；
  - 自动填充寄存器与启动流程；
  - 避免用户直接管理底层寄存器细节。

---

## 8. 里程碑（修订）

- M0：原语模块 + 单模块 DV（已完成）。
- M1：AXI-Lite 寄存器面 + top 控制链路 + 顶层基础DV。
- M2：16x16 baseline compute 路径打通（无完整DMA亦可通过本地memory model）。
- M3：S=256,d=64,causal 端到端对比（Python/Torch+RTL）。
- M4：接入 yosys/iEDA 做单模块与中层 STA。

---

## 9. 风险与对策（修订）

- 风险1：FSA 思想迁移后控制复杂度上升。
  - 对策：先做 16x16 + 简化状态机，再引入重叠优化。
- 风险2：Q8.8 精度不足。
  - 对策：exp/recip 多版本并行评估，保留参数切换。
- 风险3：顶层仿真慢。
  - 对策：缩尺 case（S=32/64）回归 + 夜间全量回归。

---

## 10. 当前执行原则

- 先保证 baseline 合规可验证；
- bonus（尤其 #9 任务队列）统一在后续独立版本，不提前掺入 baseline 主线。
