# 2026-03-15 FP8 Attention Core Tile2 流水版本报告

## 1. 目标

在已跑通的 FP8 最小路径基础上，扩展为多 token/tile 流水版本：

1. 同一 `Q` 对两个 `K/V tile` 顺序计算；
2. 每个 tile 复用同一条 QK->softmax prep->PV 路径；
3. 以时序状态机输出聚合 `ctx_sum`。

## 2. 实现

模块：

- `experiments/fp8/fa_fp8_attention_core_tile2_pipeline/base/fa_fp8_attention_core_tile2_pipeline.sv`

接口：

1. 控制：`i_start`, `o_busy`, `o_done`；
2. 数据：`i_q_vec`, `i_k_tile0/1`, `i_v_tile0/1`；
3. 数值配置：`i_score_scale_q1_14`, `i_round_mode`, `i_saturate_en`；
4. 输出：`o_ctx_sum_q4_11`。

状态机：

1. `IDLE`：等待 `start`；
2. `RUN0`：计算 tile0 并写入 `ctx_sum`；
3. `RUN1`：计算 tile1 并累加到 `ctx_sum`；
4. `DONE`：完成态，等待 `start` 拉低回到 `IDLE`。

## 3. 验证

测试文件：

- `experiments/fp8/fa_fp8_attention_core_tile2_pipeline/tb/test_fa_fp8_attention_core_tile2_pipeline.py`

验证命令：

```bash
make -C experiments verif MOD=fp8/fa_fp8_attention_core_tile2_pipeline EXP=base
```

结果：

- `samples=500`
- `mismatches=0`
- `PASS=1, FAIL=0`

## 4. 调试记录

初版测试全失败（500/500），根因不是算术错误，而是测试对 `DONE` 采样时点晚了 1 个周期：

1. 测试在 `DONE` 后又多 tick 一拍，状态已回 `IDLE`；
2. 导致 `done` 与 `ctx` 读取不一致。

修复后：

1. 在 `RUN1 -> DONE` 这个边沿后立即采样；
2. 回归全部通过。

## 5. 结论

1. FP8 路径已从单 tile 扩展到 2-tile 时序执行；
2. 已具备“可调度、可累加、可完成握手”的最小流水骨架；
3. 下一步可扩展到 N-tile 参数化，并与 Q8.8 主线接口语义对齐后做全核级验证。
