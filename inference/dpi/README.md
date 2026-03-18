# inference/dpi

该目录提供 `inference/native` 对接 RTL-DPI 的第一版骨架：

- 稳定 C API：`include/fa_dpi_backend.h`
- 任务/性能类型定义：`include/fa_dpi_types.h`
- AXI-Lite 队列提交流：`src/fa_task_queue_submit.cpp`
- Verilator 顶层封装占位：`src/fa_veri_top.cpp`
- 主存模型：`src/fa_dma_mem_model.cpp`
- smoke 测试：`tests/dpi_smoke.cpp`

> 当前默认是 `stub` 运行模式（不依赖 Verilator 生成模型），用于先打通 native 侧调用链和队列语义。

## 快速使用

```bash
cd inference/dpi
make test
```

## 后续接入真实 Verilator

1. 在 `verilator/CMakeLists.txt` 中加入 `fa_attention_ip_top.sv` 的 Verilator 生成规则。
2. 在 `FA_DPI_USE_VERILATOR=ON` 时将生成模型链接进 `fa_dpi_backend`。
3. 在 `src/fa_veri_top.cpp` 中替换当前 stub 的寄存器/队列行为为真实 AXI-Lite + AXI Master/DMA 驱动。

## 与当前 RTL 队列寄存器对齐

已对齐寄存器：

- `REG_QUEUE_CMD = 0x44`
- `REG_QUEUE_STATUS = 0x48`
- `REG_TASK_ACCEPT_COUNT = 0x50`
- `REG_TASK_DONE_COUNT = 0x54`
- `REG_TASK_ERROR_COUNT = 0x58`
- `REG_LAST_ERROR = 0x5C`

提交动作：

1. 写 staging descriptor (`Q/K/V/O/stride/neg_large/scale/cfg`)
2. 写 `QUEUE_CMD.ENQUEUE`
3. 检查 `TASK_ACCEPT_COUNT` 增量与 sticky 错误位
