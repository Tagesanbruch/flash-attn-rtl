# 2026-03-15 FP8 Full-Core 真实性复核与 CModel 误差分析报告

## 1. 你提出的问题是否成立

结论：成立。

你指出的三个现象都是真问题，不是观测误差：

1. `S=256,D=64` 下 `perf state cycles` 早先版本出现 `load_q=1 init=1 load_k=1 ... compute=252`，明显不是真实主状态占用。
2. `rtl vs fixed` 出现 `AE=0`，并不代表架构高精度，只代表参考模型与 RTL 使用了同构近似路径。
3. FP8 相对 FP32 的 `max_err` 在部分随机种子上较大（例如 `4.729657`），说明近似+量化链路存在可见误差放大场景。

## 2. 根因定位（代码级）

在 [experiments/fp8/fa_fp8_attention_core_full/base/fa_fp8_attention_core_full.sv](experiments/fp8/fa_fp8_attention_core_full/base/fa_fp8_attention_core_full.sv) 中，原本 `ms_*` 计数在 `ST_IDLE && i_start` 时采用固定赋值（例如 `ms_load_q=1`、`ms_compute=seq_len-4`），并非随主状态真实累计，这会直接导致你看到的异常分布。

同时，该 FP8 full-core 仍是简化架构：

1. 没有 Q8.8 主线那样的 DMA/Tile 真实握手路径。
2. 每行固定 `ST_SCORE -> ST_SOFTMAX -> ST_PV` 三阶段推进，周期近似 `3*S`。
3. `perf` 的部分字段属于映射占位（为了与 CSR 地址兼容），不是完整系统级统计。

## 3. 已完成修复与继续实现

### 3.1 perf state 计数修正（已改 RTL）

已把 `ms_*` 改为真实状态累计语义：

1. 启动时清零，不再预置常数。
2. 在 `ST_SCORE/ST_SOFTMAX/ST_PV` 周期内累加 `ms_compute`。
3. 其余 `ms_*` 当前保持 0（因为该 FP8 实验核尚未实现对应主状态）。

对应 cocotb 也同步更新预期口径。

### 3.2 回归结果（已复测）

命令：

```bash
make -C experiments verif MOD=fp8/fa_fp8_attention_core_full EXP=base
```

结果：`4/4 PASS`

关键日志（`S=256,D=64`）：

1. `perf summary: cycles=768 busy=768 ...`
2. `perf state cycles: load_q=0 init=0 load_k=0 load_v=0 compute=768 norm=0 write_o=0 next_q=0 dp=256 score=256 softmax=256`
3. `top numeric check (rtl vs fixed-q8.8): mae=0 max_err=0`
4. `top numeric check (rtl vs fp32): mae=0.007837 max_err=2.284736`

因此现在的 perf 至少不再“伪装成完整主状态分解”。

## 4. 为什么 Q8.8 会看到 0.000，而 FP8 不是

要区分两条口径：

1. `rtl vs fixed`：同构定点/同构近似比较。
2. `rtl vs fp32`：与高精度浮点参考比较。

Q8.8 主线里常见的“0.000”通常是 `rtl vs fixed-q8.8`，它验证的是 RTL 与固定点黄金模型一致，不等价于“与 FP32 零误差”。

FP8 同理：

1. 当前 `rtl vs fixed` 为 0，表示 Python fixed 参考与 RTL 路径同构。
2. `rtl vs fp32` 非 0，且在个别 seed 下偏大，反映的是 FP8 表示能力+近似 softmax 的误差，不是 cocotb 统计错误。

## 5. 新建 FP8 CModel（按你要求）

已创建目录：

1. [experiments/fp8/cmodel](experiments/fp8/cmodel)

已创建文件：

1. [experiments/fp8/cmodel/fp8_attention_cmodel.py](experiments/fp8/cmodel/fp8_attention_cmodel.py)
2. [experiments/fp8/cmodel/Makefile](experiments/fp8/cmodel/Makefile)

### 5.1 当前支持的比较模式

1. `rtl_strict_like`：按当前 FP8 RTL 近似（整数 exp 近似 + q4.11 输出）。
2. `proposed_online_floatexp`：按待拟架构方向的在线 softmax 浮点指数路径，再量化回 q4.11。
3. 统一与 `fp32_reference` 比较，输出 `mae/max_err`。

### 5.2 首批误差结果（S=256,D=64, seeds=3）

命令：

```bash
cd experiments/fp8/cmodel && make run
```

输出摘要：

1. `seed=20260315`：`rtl_strict_like mae=0.007837 max=2.284736`；`proposed_online_floatexp mae=0.000008 max=0.000244`
2. `seed=20260316`：`rtl_strict_like mae=0.014854 max=8.440494`；`proposed_online_floatexp mae=0.000004 max=0.000244`
3. `seed=20260317`：`rtl_strict_like mae=0.003764 max=1.511005`；`proposed_online_floatexp mae=0.000003 max=0.000244`

CSV：

1. [experiments/fp8/cmodel/out/fp8_cmodel_report.csv](experiments/fp8/cmodel/out/fp8_cmodel_report.csv)

## 6. 当前判断：架构是否有“大问题”

结论：有“未完成实现问题”，但不是“功能错误导致全错”。

1. 功能一致性（RTL vs fixed）是通的。
2. 系统级真实性（DMA/tile/完整 perf 状态）尚未完成，因此你看到的早期 perf 分布异常是合理暴露。
3. FP8 对 FP32 误差较大是当前近似路径的自然结果，不应通过“放宽阈值掩盖”，应通过 CModel+架构改造收敛。

## 7. 下一步（继续实现与测试）

1. 在 FP8 RTL 中把 `ms_load_q/load_k/load_v/write_o/norm` 从占位计数替换为真实事件驱动计数。
2. 引入可配置 `exp` 近似等级（当前整数移位版 vs PWL 版），并在 cmodel 中对齐同名模式。
3. 增加 `seed sweep`（>=20 seeds）并输出分位数统计（P50/P90/P99）用于误差门限决策。
4. 最终把 FP8 cmodel 接到 `experiments` 顶层回归目标，形成“实现-模型-报告”闭环。

## 8. 追加：20 seeds 统计（已完成）

命令：

```bash
cd experiments/fp8/cmodel && \
python3 fp8_attention_cmodel.py --s 256 --d 64 --seed 20260315 --n-seeds 20 \
  --csv-out out/fp8_cmodel_report_20seeds.csv
```

统计结果：

1. `rtl_strict_like`：
	- `mae_p50=0.016547`
	- `mae_p90=0.043468`
	- `mae_p99=0.054774`
	- `max_p50=7.334022`
	- `max_p90=10.687994`
	- `max_p99=10.963141`
2. `proposed_online_floatexp`：
	- `mae_p50=0.000005`
	- `mae_p90=0.000008`
	- `mae_p99=0.000009`
	- `max_p50=0.000244`
	- `max_p90=0.000244`
	- `max_p99=0.000244`

输出文件：

1. [experiments/fp8/cmodel/out/fp8_cmodel_report_20seeds.csv](experiments/fp8/cmodel/out/fp8_cmodel_report_20seeds.csv)

结论：

1. 当前 `rtl_strict_like` 路径误差分布有明显长尾，不能以单 seed 结果代表稳定精度。
2. 同一输入下，`proposed_online_floatexp` 显示可显著收敛误差，说明优化方向应优先放在 `exp/softmax` 数值路径，而不是继续放宽验证阈值。

## 9. 继续实现：DMA/tile 真实计数（已完成一版）

你在通知后选择了“继续做DMA/tile真实计数实现”，本轮已实现并通过回归。

实现内容（RTL）：

1. 在 [experiments/fp8/fa_fp8_attention_core_full/base/fa_fp8_attention_core_full.sv](experiments/fp8/fa_fp8_attention_core_full/base/fa_fp8_attention_core_full.sv) 新增显式阶段：`ST_LOAD_Q / ST_LOAD_K / ST_LOAD_V / ST_WRITE_O`。
2. `dma_beats` 由 `((S*D)+7)>>3` 计算，load/write 阶段按 beat 周期推进。
3. `perf_dma_rd_cmd/beat`、`perf_dma_wr_cmd/beat` 改为事件驱动累计，不再启动时一次性预填。
4. `ms_load_q/load_k/load_v/write_o/compute/next_q` 改为状态驱动累计。

同步验证（cocotb）：

1. [experiments/fp8/fa_fp8_attention_core_full/tb/test_fa_fp8_attention_core_full.py](experiments/fp8/fa_fp8_attention_core_full/tb/test_fa_fp8_attention_core_full.py) 已同步更新期望。
2. 回归命令：

```bash
make -C experiments verif MOD=fp8/fa_fp8_attention_core_full EXP=base
```

结果：`4/4 PASS`。

`S=256,D=64` 最新关键读数：

1. `cycles=8960 busy=8960`
2. `rd_cmd=3 rd_beat=6144 wr_cmd=1 wr_beat=2048`
3. `state: load_q=2048 load_k=2048 load_v=2048 compute=768 write_o=2048 next_q=255`
4. `rtl vs fixed: max_err=0`
5. `rtl vs fp32: mae=0.007837 max_err=2.284736`

说明：

1. 这仍不是完整主线 IP 级 DMA 握手实现，但相比此前“固定常数占位计数”已经升级为事件驱动计数，perf 含义显著更真实。
2. 下一步应把该计数路径对接真实数据搬运握手，而不是仅以内部 phase 计数替代。

## 10. cocotb 口径复核与标签修正

你质疑“为什么会看到 0.0 误差”后，我复查了 cocotb 输出并修正了一个容易误导的点：

1. 原日志标签是 `rtl vs fixed-q8.8`，这在 FP8 测试里命名不准确。
2. 现已改为 `rtl vs fixed-fp8-model`（文件：
	[experiments/fp8/fa_fp8_attention_core_full/tb/test_fa_fp8_attention_core_full.py](experiments/fp8/fa_fp8_attention_core_full/tb/test_fa_fp8_attention_core_full.py)）。
3. 该项为 0 仅表示“RTL 与同构 FP8 fixed 参考一致”；
	不代表“RTL 与 FP32 无误差”。

同时，和 Q8.8 主线对比后的严格结论是：

1. 当前 FP8 仍缺少像 Q8.8 那样完整的 top-level DMA ready/valid 互联与寄存器驱动链路。
2. 本轮已完成的是“阶段+beat 事件驱动计数真实化”，不是最终形态。
3. 下一轮必须把 FP8 路径进一步向 Q8.8 的顶层接口形态靠拢（而不是继续在单模块里做近似）。
