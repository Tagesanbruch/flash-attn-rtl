# 2026-03-18 inference/native ↔ RTL DPI 对接与统一算子复用分析

## 0. 背景与当前分支语义

- 当前代码基线关系：`baseline -> bonus9-task-queue -> 当前分支`。
- 目前 RTL 主线能力：
  - `fa_attention_ip_top` 已落地 task FIFO（`FIFO_DEPTH` 参数化，默认 4）。
  - AXI-Lite 队列控制/状态寄存器已可用（`REG_QUEUE_CMD=0x44`，`REG_QUEUE_STATUS=0x48`，`TASK_*_COUNT`）。
  - 顶层已支持 descriptor 校验、overflow/underflow/desc_error sticky、auto scheduler。
- inference 侧现状：
  - `inference/native/run_fa.c` 已把 attention 路径替换为 `flash_attention_forward()`。
  - `flash_attn.c` 当前是“软件 C-model 仿 RTL”，不是 DPI / Verilator 真实 RTL 跑法。
  - `inference/dpi/` 目录为空。

---

## 1. 问题（1）：`fa_core_q8_8` 与 RTL->DPI 对接架构

## 1.1 现状接口解读（native 侧）

当前调用链：

1. `run_fa.c` 在每层 attention 里调用：
   - `flash_attention_forward(s->q, s->key_cache+loff, s->value_cache+loff, s->xb, pos, n_heads, head_size, kv_mul, kv_dim, scale)`
2. `flash_attention_forward()` 完成：
   - FP32 -> Q8.8 量化
   - 按 head 并行调用 `fa_core_q8_8()`
   - Q8.8 -> FP32 回写
3. `fa_core_q8_8()` 内部是软件 online-softmax 模拟。

关键观察：
- `flash_attention_forward()` 的 `scale` 入参当前未真正用于 `fa_core_q8_8`，函数内自行按 `1/sqrt(head_size)`计算；后续接 DPI 时应统一语义。
- `fa_core_q8_8()` 循环 `for (t=0; t<=seq_len)`，与上层传 `pos` 的约定是匹配的（有效长度为 `pos+1`）。

## 1.2 推荐分层：保持 `run_fa.c` 稳定，替换 backend

建议把现有 `flash_attn.c` 重构为“前端 + backend 适配层”：

- 前端（保留）：
  - `flash_attention_forward()`：负责量化/反量化与张量切片。
- backend（新增多实现）：
  - `FA_BACKEND_SW`：现有 `fa_core_q8_8`（回归基线）。
  - `FA_BACKEND_DPI`：调用 `inference/dpi` 的 C API，触发 Verilated RTL。

这样可做到：
- 推理主程序不改算法流程。
- 仅通过环境变量或编译宏切换 backend。
- 同一套 trace 和精度评估路径可对比 SW vs DPI。

## 1.3 DPI 目录建议（`inference/dpi`）

建议一次性引入以下骨架：

```text
inference/dpi/
  include/
    fa_dpi_backend.h          # 给 C 侧调用的稳定 API
    fa_dpi_types.h            # descriptor / status / perf 结构体
  src/
    fa_dpi_backend.cpp        # C API 实现（extern "C"）
    fa_veri_top.cpp           # Verilator top 封装
    fa_axil_driver.cpp        # AXI-Lite 读写辅助
    fa_dma_mem_model.cpp      # 主存模型（Q/K/V/O映射）
    fa_task_queue_submit.cpp  # 基于队列寄存器的提交逻辑
  verilator/
    CMakeLists.txt            # Verilator + C++ 构建
    verilator_flags.cmake
  tests/
    dpi_smoke.cpp             # 最小端到端冒烟（单 task）
    dpi_queue4.cpp            # 4-task FIFO 提交流
  Makefile                    # 本地入口（macOS clang++）
```

## 1.4 C API 设计（建议）

建议给 native C 端暴露最小 API：

- `fa_dpi_init(const fa_dpi_init_cfg_t*)`
- `fa_dpi_submit_task(const fa_task_desc_t*)`
- `fa_dpi_wait_idle(uint32_t timeout_cycles)`
- `fa_dpi_read_perf(fa_perf_snapshot_t*)`
- `fa_dpi_shutdown()`

其中 `fa_task_desc_t` 与当前 `REG_*` 强对应：
- `q_base/k_base/v_base/o_base`
- `stride_bytes`
- `scale_q8_8`
- `neg_large_q8_8`
- `causal_en`

并映射到现有队列语义：
- 写 staging regs
- 写 `REG_QUEUE_CMD[0]=ENQUEUE`
- 轮询 `REG_QUEUE_STATUS.queue_ready_for_enqueue`
- 读 `TASK_ACCEPT_COUNT / TASK_DONE_COUNT`

## 1.5 与 task queue 的调度结合（推理侧）

### Decode（pos 递增）

每层每 head 都是一个独立 attention task，可做“层内小批提交”：

- 以 `layer` 为粒度，按 head 提交 `N` 个 descriptor。
- 当 `FIFO_DEPTH=4` 时，采用滑窗提交：
  - 先塞满 4
  - 运行中继续补队
  - 直到该层 head 全完成

### Prefill

prefill token 数多时，可考虑“按 token 分块 + per-head 连续提交”，但首版建议保守：
- 先只替换 decode 第一阶段或短上下文路径。
- 确保 correctness 与吞吐统计先闭环。

## 1.6 构建系统建议（macOS M4）

在 `inference/native/Makefile` 增加：

- `run_fa_sw`：现有 `run_fa.c + flash_attn.c`
- `run_fa_dpi`：`run_fa.c + flash_attn_frontend.c + libfa_dpi_backend.a`

DPI 子构建建议独立：
- `make -C inference/dpi all`
- 输出静态库与头文件，再被 native 链接。

注意点：
- 保持与当前 `clang/clang++` 一致工具链。
- Verilator 生成的 C++ 目标只在 `inference/dpi` 内部可见，避免污染 native 编译命令。

---

## 2. trace 需要补充什么信息

## 2.1 当前 trace 覆盖情况

`run_fa.c` 当前 trace 主要记录：
- 层级步骤名
- 张量 shape
- attention 子过程的“理论次数”

存在缺口：

1. 仅对 `pos==0`（prefill首 token）和 `pos==prompt_token_num`（decode首 token）开 trace，不是全程。
2. 没有记录每层/每阶段真实耗时（trace 文件里缺 timing）。
3. 没有记录量化误差信息（FP32↔Q8.8 前后偏差）。
4. 没有记录 head 级 dispatch 明细（哪个 head 对应哪个 task）。
5. 没有记录队列行为（enqueue/dequeue/count/free_slots）。
6. `count_attn_dot / count_attn_v` 在当前路径未更新，最终计数打印会失真。
7. 没有 RTL perf counter 映射（run_count/dma_beats/comp_launch 等）。

## 2.2 建议新增 trace 字段（按优先级）

### P0（立即可加）
- `layer/head/pos` 三级标签
- `seq_len_eff=pos+1`
- `backend=SW|DPI`
- `q_quant_mae/maxae`、`k_quant_mae/maxae`、`v_quant_mae/maxae`
- `attn_out_dequant_mae/maxae`（对 FP32 参考）

### P1（DPI接通后）
- `task_submit_id/task_done_id`
- `queue_count/free_slots/overflow/desc_error`
- `rtl_cycles_this_task`
- `dma_rd_cmd/beat`, `dma_wr_cmd/beat`

### P2（统一调度期）
- `op_type`（ATTN/GEMV/GEMM）
- `descriptor_size_bytes`
- `scheduler_wait_cycles`

---

## 3. 问题（2）第一部分：`trace.log` 是否完整记录了运算 trace

结论：当前是“结构流程 trace”，不是“可用于软硬协同优化的性能 trace”。

- 结构流程：基本完整（Q/K/V投影、RoPE、attention、O_proj、FFN步骤均有）。
- 性能与数据质量：不完整（缺 per-layer timing、缺量化误差、缺队列/DMA/寄存器交互信息）。

因此建议把现有 trace 升级为两层：
1. **human-readable**（当前风格，便于快速看流程）
2. **machine-readable CSV/JSONL**（用于自动分析、画图、回归对比）

---

## 4. 问题（2）第二部分：GEMM/GEMV 是否也是主要瓶颈

结论：是，而且在当前 LLM 形态下通常比 attention 更重。

以 `Qwen2.5-0.5B`（`dim=896, hidden=4864, n_heads=14, head_size=64`）按每层每 token 估算：

- `QKV`：`dim*dim + 2*dim*kv_dim = 896*896 + 2*896*128 = 1,032,192 MAC`
- `O_proj`：`dim*dim = 802,816 MAC`
- `FFN`：`3*dim*hidden = 3*896*4864 = 13,074,432 MAC`
- `Attention(QK+PV)`：约 `2*n_heads*(pos+1)*head_size = 1792*(pos+1)`

在常见 decode 长度下（例如 `pos=128` 或 `256`），attention 增长明显，但 FFN + 投影 GEMM/GEMV 仍是总算量主导。

所以：
- 只加速 attention 可以显著优化某些阶段，但端到端上限受 GEMM/GEMV 约束。
- 若目标是更高整机吞吐，统一算子复用是合理方向。

---

## 5. 复用 FlashAttention IP 到 GEMM/GEMV：RTL 修改建议

## 5.1 原则：复用“dotproduct 引擎”，不直接硬改整条 attention 控制流

当前 `fa_attention_core` 是强 attention 专用 FSM：
- Q/K/V tile 装载
- online softmax 状态（`row_m/row_l/row_acc`）
- normalize 写回

若直接在该 FSM 上塞 GEMM/GEMV 分支，复杂度和验证风险都高。

更稳妥：
- 抽象并复用 `fa_qk_dotprod_slice` 及其并行归约路径，形成统一 `dot engine`。
- 在 top/scheduler 侧增加 `op_type` + descriptor 驱动不同“算子微程序”。

## 5.2 建议的两阶段 RTL 路线

### 阶段 A（低风险，优先）

新增独立模块：`fa_dot_compute_core`（Q8.8）
- 支持 `GEMV`: `y = A*x`
- 支持 `small GEMM tile`: `C[m,n] += A[m,k] * B[k,n]`
- 内部复用 `DP_LANES` 与归约树
- 暂不引入 softmax/recip

顶层改动：
- 在 `task descriptor` 增加 `op_type`（2~3 bit）
- scheduler dequeue 后按 `op_type` 启动 `attention_core` 或 `dot_compute_core`
- 保持同一 FIFO / 计数器框架

### 阶段 B（统一调度增强）

- 扩展 descriptor：
  - `M/N/K`
  - `lda/ldb/ldc`
  - `base_a/base_b/base_c`
  - `acc_mode`（overwrite/accumulate）
- 新增 perf counter：
  - `dot_task_count`
  - `dot_mac_count`
  - `dot_dma_*`

## 5.3 寄存器与 descriptor 扩展建议

在不破坏 baseline/bonus9 的前提下：

- 现有 staging regs 保留给 ATTN 公共字段。
- 新增扩展区（例如 `0x60~0x7C`）给 GEMM/GEMV：
  - `A_BASE/B_BASE/C_BASE`
  - `M/N/K`
  - `LDA/LDB/LDC`
  - `OP_TYPE`（或放入 `CFG2`）

如果希望更整洁，可定义“固定 256-bit descriptor 格式”：
- 低位兼容 ATTN 字段
- 高位复用 GEMM 扩展

## 5.4 任务队列调度策略（推理端）

- `ATTN` 与 `GEMV/GEMM` 共用 FIFO，按提交顺序执行。
- Host 侧策略：
  - 保持层内 DAG 顺序（先 QKV，再 ATTN，再 O_proj，再 FFN）
  - 同算子尽量连续入队，提高数据局部性
- 后续可扩展：
  - 两级队列（ATTN 队列、DOT 队列）+ 简单仲裁
  - 但首版不建议引入重排序，避免破坏可验证性

---

## 6. 验证与落地建议

## 6.1 DPI 接通最小闭环（建议立即执行）

1. `inference/dpi` 建立 C API + Verilator wrapper。
2. 在 native 侧支持 backend 切换（SW/DPI）。
3. 先做单层单 head 单 task 对齐（Q8.8 输入下 bit-exact 或误差可解释）。
4. 再做 `FIFO_DEPTH=4` 多 task drain。
5. 最后接入 `run_fa.c` decode 首 token 实跑。

## 6.2 统一算子复用最小闭环

1. 先做 GEMV（比 GEMM 更简单）。
2. 复用 queue + perf 框架，不改 ATTN 主路径行为。
3. 加一个 “Q8.8 GEMV C-model vs RTL” 独立回归。
4. 再考虑 GEMM micro-tile。

---

## 7. 风险与注意事项

1. **功能风险**：若直接改 `fa_attention_core` 大 FSM，容易回归破坏 `85,928 cycles` 既有主线。
2. **接口风险**：descriptor 扩展若与既有寄存器语义冲突，会影响现有 cocotb 用例。
3. **性能风险**：DPI 仿真吞吐慢，不代表真实硬件吞吐；需以 cycle/perf counter 为准。
4. **精度风险**：统一 Q8.8 对 GEMM/FFN 的精度影响可能比 attention 更敏感，需增加端到端质量监控。

---

## 8. 建议的近期执行顺序

### Step-1（立即）
- 完成 `inference/dpi` 骨架 + `run_fa` backend 切换。

### Step-2
- 补 trace（CSV/JSONL）与队列/寄存器可观测性。

### Step-3
- 先做 `GEMV` 原型（独立 core + 同队列调度）。

### Step-4
- 评估是否推进到 GEMM tile 化与多模式统一 IP。

---

## 9. 本文对应的问题回答摘要

- 对接方案：建议“前端不动，backend 分层”，在 `inference/dpi` 新建 Verilator+AXI wrapper 与 task queue 驱动。
- trace 补充：需从“流程文本”升级到“性能/误差/队列可观测”。
- GEMM/GEMV 瓶颈：是主要瓶颈，尤其 FFN 与投影矩阵乘。
- RTL 改造：优先复用 dot engine + 统一队列 descriptor，不建议直接大改 attention FSM。
