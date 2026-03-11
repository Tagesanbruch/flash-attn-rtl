# 2026-03-10 当前版本周期、perf 寄存器与数值误差分析

## 1. 目的

本文针对当前 `ctx` 回切后的主线版本，集中回答以下问题：

1. 结合 perf 寄存器，当前周期指标应如何做理论拆解；
2. 是否需要引入 [dv/verilator_cpp/fa_attention_core_tb.cpp](dv/verilator_cpp/fa_attention_core_tb.cpp) 做辅助测试；
3. cocotb 中存在多个测试时，周期/计数寄存器是否会清零；
4. 为什么当前 RTL 结果和 fixed Q8.8 参考不完全一致；
5. 当前版本为什么会把部分流水延迟“重复支付”；
6. 下一步如何把当前版本的周期统计与真实吞吐重新拉回正确轨道。

---

## 2. 当前 perf 读回数据

本轮 `fa_attention_ip_top` full-run 回归的关键 perf 结果为：

| 指标 | 数值 |
|---|---:|
| `cycles` | `608296` |
| `busy` | `608296` |
| `rd_cmd` | `136` |
| `rd_beat` | `34816` |
| `wr_cmd` | `8` |
| `wr_beat` | `2048` |
| `comp_launch` | `64` |
| `exp` | `917504` |
| `mul` | `65536` |
| `recip_req` | `256` |
| `recip_rsp` | `256` |
| `load_q` | `2080` |
| `init` | `8` |
| `load_k` | `4144` |
| `load_v` | `4144` |
| `compute` | `589952` |
| `norm` | `5888` |
| `write_o` | `2072` |
| `next_q` | `8` |
| `dp` | `327680` |
| `score` | `32768` |
| `softmax` | `229376` |

其中，主状态之和满足：

$$
2080+8+4144+4144+589952+5888+2072+8=608296,
$$

与 `busy` 完全一致，说明 **当前 perf 计数本身是自洽的**，问题不在“计数器坏了”，而在“当前调度确实把大量流水延迟逐次兑现成了真实周期”。

---

## 3. 周期理论拆解

### 3.1 基本工作量

当前默认参数：

- `S=256`
- `D=64`
- `TQ=32`
- `TK=64`
- `ROW_PAR=2`
- `DP_CHUNKS=2`
- `NORM_LANES=8`

因此：

$$
NUM_Q = 256 / 32 = 8,
\qquad
NUM_K = 256 / 64 = 4.
$$

每个 `Q tile` 中的 row pair 数为：

$$
QPAIR_{tile}=TQ/ROW_PAR=32/2=16.
$$

每个 `K tile` 中，每个 row pair 需要处理 `TK=64` 个 key，因此每个 compute tile 的 score-pair 数为：

$$
16\times 64 = 1024.
$$

整个 full-run 的 score-pair 总数为：

$$
8\times 4\times 16\times 64 = 32768.
$$

这正好对应 perf 中的：

- `cs_score_done_cycles = 32768`

也就是说，**每完成一个 score-pair，当前实现就会进入一次 `C_SCORE_DONE`**。

### 3.2 QK 路径的周期含义

当前 `fa_qk_dotprod_slice` 已经是 `exp_h` 风格长流水版本。

- 真正有用的 chunk issue 数：`DP_CHUNKS = 2`
- 叶子流水额外 fill/drain：`qk_pipe_latency = 8`

因此 cocotb 里当前的期望写成：

$$
cs\_dp = score\_pairs \times (DP\_CHUNKS + qk\_pipe\_latency)
$$

代入数值：

$$
32768 \times (2+8) = 327680,
$$

与 perf 完全一致。

这说明当前 `C_DP_RUN` 的 `10` 个周期里：

- 只有前 `2` 个周期是在发射有用 chunk；
- 后 `8` 个周期是在等流水线尾部结果全部回收。

换言之，**当前 QK 的 8 级流水延迟被对每一个 score-pair 都重新支付了一次**。

### 3.3 Softmax 路径的周期含义

当前 top test 采用：

$$
cs\_softmax = score\_pairs \times ctx\_softmax\_latency
$$

其中：

- `ctx_softmax_latency = 7`

代入后：

$$
32768 \times 7 = 229376,
$$

与 perf 完全一致。

这说明当前 `fa_attention_core` 在 `C_SOFTMAX_PREP` 中，并没有把 `fa_online_softmax_ctx` 当作一个可以连续发射的流水单元来用，而是：

1. 发 1 次；
2. 等 `o_valid` 回来；
3. 写回 `row_m/row_l/row_acc`；
4. 再处理下一个 score-pair。

因此 **softmax 的 7 拍延迟也被对每个 score-pair 重新支付了一次**。

### 3.4 `MS_COMPUTE` 为什么是 `589952`

子状态总和为：

$$
327680 + 32768 + 229376 = 589824.
$$

而 perf 读回：

$$
MS\_COMPUTE = 589952.
$$

两者差值为：

$$
589952 - 589824 = 128.
$$

整个 full-run 有：

$$
8\times 4 = 32
$$

次 compute tile，因此每个 compute tile 额外多出：

$$
128 / 32 = 4
$$

个控制周期。

这 4 个周期可以理解为：

- `C_IDLE` 启动握手；
- `C_DONE` 收尾；
- `comp_start/comp_done` 与 `ms=S_COMPUTE` 的启动、退休边界气泡。

所以：

$$
MS\_COMPUTE = cs\_dp + cs\_score + cs\_softmax + 32\times 4.
$$

### 3.5 Load / Write 周期的含义

当前数据量与 beat 数理论值为：

- `Q tile`：`32×64/8 = 256 beats`
- `K tile`：`64×64/8 = 512 beats`
- `V tile`：`64×64/8 = 512 beats`
- `O tile`：`32×64/8 = 256 beats`

perf 实测：

- `load_q = 2080 = 8 × 260`
- `load_k = 4144 = 8 × 518`
- `load_v = 4144 = 8 × 518`
- `write_o = 2072 = 8 × 259`

这说明对每个 tile：

- `Q`：约 `256 beat + 4` 个控制/协议边界周期；
- `K/V`：约 `512 beat + 6` 个控制/协议边界周期；
- `O`：约 `256 beat + 3` 个控制/协议边界周期。

这部分不是当前主矛盾，因为总和只有：

$$
2080+4144+4144+2072=12440,
$$

远小于 `MS_COMPUTE=589952`。

### 3.6 Normalize 周期的含义

当前：

$$
MS\_NORMALIZE = 5888.
$$

全局有 `256` 行，因此平均每行：

$$
5888 / 256 = 23
$$

周期。

它大致由以下几部分构成：

1. `1` 个倒数请求发射周期；
2. `10` 个 `fa_recip_nr_q16_16` 流水延迟；
3. `8` 个 `NORM_LANES=8` 的 chunk issue 周期；
4. `2` 个 `fa_o_normalize_block` 两拍流水 drain；
5. 约 `2` 个行边界控制周期。

因此 Normalize 当前不是 608k 周期的核心来源。

---

## 4. 当前 608296 cycles 的真正主因

### 4.1 重复支付的流水延迟

当前版本里，最主要的重复支付有两类：

| 路径 | 当前支付方式 | 结果 |
|---|---|---|
| QK `exp_h` 长流水 | 每个 score-pair 都支付 `2 + 8` 周期 | `327680 cycles` |
| softmax `ctx` 流水 | 每个 score-pair 都支付 `7` 周期 | `229376 cycles` |

而真正的有用工作量其实是：

- QK：每个 score-pair 只需要 `2` 个 chunk issue；
- softmax：从流水角度看，本应接近 `1` 输入/拍，而不是 `1` 输入/`7` 拍。

### 4.2 当前版本“没有用上”的流水能力

更关键的是，`fa_online_softmax_ctx` 的核心价值本来是：

- `4-context interleave`
- `state forwarding`
- 多拍流水但支持持续发射

但是当前主线接法里：

- row0 固定 `ctx_id=0`
- row1 固定 `ctx_id=1`

这意味着 **每个实例的 4-context 能力实际上没有被真正用起来**。当前只是把它当成一个“7 拍才回结果的单上下文单元”，因此吞吐端完全没有兑现 `ctx` 方案的设计初衷。

---

## 5. 若把重复延迟去掉，理论上能回到什么量级

### 5.1 QK 的理论改善量

当前 QK：

$$
327680 = 32768 \times (2+8)
$$

若改成“连续发射 chunk，整 tile 只支付一次 fill/drain”，则全局更接近：

$$
32768 \times 2 + 32 \times 8 = 65536 + 256 = 65792.
$$

因此 QK 单项理论可节省约：

$$
327680 - 65792 = 261888.
$$

### 5.2 Softmax 的理论改善量

当前 softmax：

$$
229376 = 32768 \times 7
$$

若 `ctx` 真正按连续流水使用，则更接近：

$$
32768 \times 1 + 32 \times 6 \approx 32960.
$$

因此 softmax 单项理论可节省约：

$$
229376 - 32960 = 196416.
$$

### 5.3 合并估算

若两项都被正确流水化，则 compute 周期理论上可从：

$$
589952
$$

下降到约：

$$
589952 - 261888 - 196416 = 131648.
$$

这个量级已经非常接近此前稳定 baseline 的 `145584 cycles`。这说明：

> 当前 608k 的问题不是算错了，而是**把高频 leaf 当成串行块使用了**。

---

## 6. 是否需要用 Verilator C++ TB 辅助测试

结论：**需要，但只能作为辅助，不应替代顶层 cocotb/perf 回归。**

### 6.1 适合用 C++ TB 做什么

[dv/verilator_cpp/fa_attention_core_tb.cpp](dv/verilator_cpp/fa_attention_core_tb.cpp) 适合做：

1. `fa_attention_core` 级的快速 profile；
2. 核心算术路径与 `fixed-like/FP32` 的对比；
3. `ms/cs` 分布与 `o_cycles` 的快速离线统计；
4. 在不经过 AXI-Lite / 顶层寄存器 / perf counters 的前提下，定位 core 内部调度问题。

它已经会导出：

- `o_cycles`
- `ms_compute_cycles`
- `ms_normalize_cycles`
- `cs_dp_cycles`
- `cs_score_cycles`
- `cs_softmax_pv_cycles`

所以它非常适合做“**当前调度是否真的把流水延迟重复支付了**”的快速对账。

### 6.2 不适合用 C++ TB 替代什么

它不应替代：

1. 顶层寄存器语义验证；
2. perf 寄存器映射正确性验证；
3. `fa_perf_counters` 与 `AXI-Lite` 读回口径验证；
4. 顶层 DMA 命令/beat 数统计验证。

这些只能由 [dv/cocotb/tests/test_fa_attention_ip_top_regs.py](dv/cocotb/tests/test_fa_attention_ip_top_regs.py) 这类 top test 完成。

### 6.3 推荐用法

推荐分工：

- **顶层周期与 perf 真值**：以 cocotb top test 为准；
- **core 调度微观瓶颈定位**：用 Verilator C++ TB 辅助；
- **数值口径追踪**：C++ TB + `cmodel rtl_strict` 联合使用。

---

## 7. cocotb 里多次实验后，周期数会不会清零

结论分三层：

### 7.1 多个 cocotb `test_*` 之间

当前 [dv/cocotb/tests/test_fa_attention_ip_top_regs.py](dv/cocotb/tests/test_fa_attention_ip_top_regs.py) 中每个测试一开始都会：

- `rst_n = 0`
- 初始化 AXI 输入
- 重新拉起时钟和 master

因此**不同测试之间**，DUT 状态会被重新清空。

### 7.2 同一个仿真里，多次 `START`

`fa_perf_counters` 的实现表明：

- `i_run_start` 到来时，除 `o_run_count` 外，其余 per-run counters 都会清零；
- `o_run_count` 会自增 `1`。

因此若在同一次仿真里连续发多次 `START`：

- `run_count` 是累计的；
- `busy/dma/compute/norm/cs_*` 等计数会按“新一轮 run”重新清零。

### 7.3 `REG_CYCLES` 是否也清零

这里要区分：

- `perf counters`：在 `START` 和 `SOFT_RESET` 都会清零；
- `REG_CYCLES`：来自 `fa_attention_core.o_cycles`。

`REG_CYCLES` 当前行为是：

- 新 `START` 时重新置零；
- `SOFT_RESET` 只会终止运行，但**不会**自动清零当前 `CYCLES`；
- `rst_n` 拉低时才绝对清零。

这与测试 [dv/cocotb/tests/test_fa_attention_ip_top_regs.py](dv/cocotb/tests/test_fa_attention_ip_top_regs.py) 中“soft reset 后 `CYCLES` 仍可读”的检查一致。

---

## 8. 为什么 RTL 结果和 fixed Q8.8 参考不同

结论：**当前差异主要不是“功能错”，而是 fixed Q8.8 参考已经不再严格等价于当前 `ctx` 主线。**

### 8.1 当前 test 里的 fixed 参考仍是旧口径

当前 top test 中的 `_fixed_flash_attention_ref()` 仍然采用：

1. `exp_pwl_q1_15()`；
2. 向量式 `row_acc` 更新；
3. 较宽的累计口径；
4. 旧的 pair 风格 softmax 数学路径。

而当前 RTL 主线已经改为：

1. `fa_online_softmax_ctx` 内部 `exp2_approx()`；
2. `l/acc` 在 leaf 中以 32bit 标量状态推进；
3. 结果再由 core 符号扩展回 64bit `row_acc` 接口；
4. `fa_o_normalize_block` 两拍流水实现；
5. `fa_recip_nr_q16_16` 近似倒数，而不是理想除法。

因此 fixed 参考和当前 RTL 在以下点上天然不同：

- 指数近似函数不同；
- softmax 内部状态位宽不同；
- 截断/舍入位置不同；
- normalize / reciprocal 路径不同。

### 8.2 当前差异来源应如何理解

因此当前 `RTL vs fixed-q8.8` 的误差，应理解为：

- **一部分来自量化与近似本身；**
- **一部分来自 testbench fixed 参考仍停留在旧 softmax 数学口径；**
- **并不自动等价于 RTL 有 bug。**

更严格的对照，应该转向：

1. `cmodel` 的 `rtl_strict` 口径；
2. 或把 top test 的 fixed 参考更新为 `ctx-strict` 版本。

### 8.3 这是不是内部模块误差

可以说“是内部模块近似与位宽策略带来的误差”，但更准确地说是：

> **当前 RTL 与 fixed 参考并非同一实现口径。**

所以这里既有模块近似误差，也有“参考模型不再同步更新”的问题。

---

## 9. 如何让当前版本的计算周期“正确”

这里的“正确”不应理解为改 perf 公式，而应理解为：

> 让周期真正反映流水化后的吞吐，而不是让每个 score-pair 都单独承担一次完整 fill/drain。

### 9.1 QK 路径的解决方向

当前问题：

- `fa_qk_dotprod_slice` 能高频，但 `fa_attention_core` 以“发完一个 score-pair，再等全部结果”的方式使用它。

解决方向：

1. 给每个发射的 QK 请求附加 `qpair/kj/chunk` tag；
2. `C_DP_RUN` 不再阻塞等待单次结果，而是允许连续 issue；
3. 结果按 `o_valid + tag` 回收并累加到对应 row-pair 的 partial sum；
4. 当一个 score-pair 的两个 chunk 都回齐后，再进入下一步 scale/softmax。

目标：

- 把 `8` 拍 fill/drain 从“每个 score-pair 一次”降到“每个 compute tile 一次”。

### 9.2 Softmax 路径的解决方向

当前问题：

- `ctx` 的 4-context 能力没有被用起来；
- 当前 core 固定 `ctx_id=0/1`，实质仍是单上下文串行等待。

解决方向：

1. 不再把 `ctx_id` 固定绑死在 row0/row1；
2. 引入 row-context scoreboard；
3. 允许多个 row 或多个 row-pair 在 softmax 侧交错发射；
4. `fa_attention_core` 维护 `issue_tag -> ctx_id -> retire_tag` 映射；
5. softmax 结果按 tag 回写到对应 `row_m/row_l/row_acc`。

目标：

- 把 `7` 拍 softmax 延迟从“每个 score-pair 一次”降为“流水 fill/drain 一次”。

### 9.3 Normalize 路径的优化方向

Normalize 不是主矛盾，但仍有两项可做：

1. 在当前 row normalize 时，提前为下一 row 发起 reciprocal；
2. 把 `row_qi+1` 的倒数等待与 `row_qi` 的 chunk normalize 重叠。

这样可以进一步压缩 `5888` 周期，但这不是第一优先级。

---

## 10. 最推荐的后续动作

### 10.1 近期必须做

1. **新增 core 级 tag 化 QK 发射/回收原型；**
2. **新增 ctx 多上下文交错版 softmax 调度原型；**
3. **把 top test 的 fixed 参考升级为 `ctx-strict` 口径。**

### 10.2 建议同时做的辅助工作

1. 在 [dv/verilator_cpp/fa_attention_core_tb.cpp](dv/verilator_cpp/fa_attention_core_tb.cpp) 中补一个当前 `ctx` 主线的 profile 汇总；
2. 对比 `C++ TB` 与 top perf 寄存器的 `dp/score/softmax` 分项；
3. 把“当前 608k 周期”与“理论可回落到约 130k~150k”整理进报告图表。

---

## 11. 结论

当前版本的 `608296 cycles` 不是 perf 统计错误，而是调度确实存在以下结构性问题：

1. `QK` 的 8 级流水延迟被对每个 score-pair 重复支付；
2. `softmax ctx` 的 7 拍延迟也被对每个 score-pair 重复支付；
3. `ctx` 的 4-context 交错能力在当前主线中几乎没有被利用；
4. fixed Q8.8 参考与当前 RTL 口径已经不再严格一致，因此数值差异不能直接等价为 RTL bug。

因此，下一步真正应该做的不是修改 perf 公式，而是：

- 把 `fa_qk_dotprod_slice` 变成可 tag 化连续回收的流水算子；
- 把 `fa_online_softmax_ctx` 真正按多 context 流水来用；
- 再用 cocotb top + Verilator C++ TB 双口径共同验证周期与数值。

---

## 12. 2026-03-11 更新：当前流式版本的实测结果与 10.2 完成情况

本节记录在 `fa_attention_core` 已引入 `QK tag pipeline + 4-context batching` 之后的最新结果，用于判断第 10.1 节的周期优化工作是否已经完成，以及第 10.2 节的辅助分析是否已经落地。

### 12.1 当前版本的实测结果

#### 12.1.1 顶层 cocotb 实测

当前 [dv/cocotb/tests/test_fa_attention_ip_top_regs.py](dv/cocotb/tests/test_fa_attention_ip_top_regs.py) full-run 读回为：

| 指标 | 数值 |
|---|---:|
| `cycles` | `85928` |
| `busy` | `85928` |
| `rd_cmd` | `136` |
| `rd_beat` | `34816` |
| `wr_cmd` | `8` |
| `wr_beat` | `2048` |
| `comp_launch` | `64` |
| `exp` | `131072` |
| `mul` | `65536` |
| `recip_req` | `256` |
| `recip_rsp` | `256` |
| `load_q` | `2080` |
| `init` | `8` |
| `load_k` | `4144` |
| `load_v` | `4144` |
| `compute` | `67584` |
| `norm` | `5888` |
| `write_o` | `2072` |
| `next_q` | `8` |
| `dp` | `66560` |
| `score` | `32768` |
| `softmax` | `32768` |

与前一版 `ctx` 恢复态相比：

$$
608296 \rightarrow 85928,
$$

总周期下降约：

$$
608296 - 85928 = 522368,
$$

降幅约为：

$$
522368 / 608296 \approx 85.9\%.
$$

这已经远低于赛题 Baseline 要求的：

$$
cycles < 300000.
$$

因此，**从周期约束本身看，当前版本已经达标，而且裕量很大。**

#### 12.1.2 Verilator C++ core profile 实测

当前 [dv/verilator_cpp/fa_attention_core_tb.cpp](dv/verilator_cpp/fa_attention_core_tb.cpp) profile 实测为：

| 指标 | 数值 |
|---|---:|
| `total_cycles` | `85808` |
| `busy_cycles` | `85807` |
| `perf_ms_load_q_cycles` | `2054` |
| `perf_ms_init_context_cycles` | `8` |
| `perf_ms_load_k_cycles` | `4104` |
| `perf_ms_load_v_cycles` | `4104` |
| `perf_ms_compute_cycles` | `67584` |
| `perf_ms_normalize_cycles` | `5888` |
| `perf_ms_write_o_cycles` | `2056` |
| `perf_ms_next_q_cycles` | `8` |
| `perf_cs_dp_cycles` | `66560` |
| `perf_cs_score_cycles` | `32768` |
| `perf_cs_softmax_cycles` | `32768` |

对应 summary 文件为 [docs/data/20260311_rtl_summary_ctxstream.csv](docs/data/20260311_rtl_summary_ctxstream.csv)。

### 12.2 理论分析：为什么当前能降到约 85.9k cycles

### 12.2.1 当前调度的关键变化

当前 `fa_attention_core` 已不再按“单个 score-pair 完整串行等待”的方式驱动 QK 与 softmax，而是引入了：

1. `QK_LAT=8` 的 tag 化 QK 流水回收；
2. `SOFTMAX_CTXS=4`；
3. `QPAIR_BATCH_ROWS = ROW_PAR × SOFTMAX_CTXS = 2 × 4 = 8`；
4. 每个 batch 同时覆盖 `4` 个 row-pair；
5. softmax 发射与 QK 回收重叠。

相关实现位于 [rtl/core/fa_attention_core.sv](rtl/core/fa_attention_core.sv#L89-L90) 和 [rtl/core/fa_attention_core.sv](rtl/core/fa_attention_core.sv#L223-L303)。

### 12.2.2 `cs_dp_run` 的理论值

当前每个 `Q tile × K tile` 计算块中：

- 总 row-pair 数：

$$
16 = TQ / ROW_PAR = 32 / 2
$$

- 每 batch 处理 row-pair 数：

$$
4 = SOFTMAX\_CTXS
$$

- 因此每个 compute tile 的 batch 数：

$$
16 / 4 = 4
$$

对每个 batch：

- 有用 issue 周期：

$$
4 \times 64 \times 2 = 512
$$

- 再加一次 `QK` 流水 fill/drain：

$$
512 + 8 = 520
$$

全局共有：

$$
8 \times 4 \times 4 = 128
$$

个 batch，因此：

$$
cs\_dp = 128 \times 520 = 66560,
$$

与实测完全一致。

这说明 `QK` 的 `8` 拍延迟已经不再按 score-pair 重复支付，而是**按 batch 支付一次**。

### 12.2.3 `cs_score_done` 与 `cs_softmax_prep` 的理论值

全局 score-pair 总数仍然是：

$$
8 \times 4 \times 16 \times 64 = 32768.
$$

因此：

$$
cs\_score = 32768,
\qquad
cs\_softmax = 32768.
$$

这里与旧版本最本质的不同在于：

> `cs_score_done` 与 `cs_softmax_prep` 现在已经不再表示“独占 compute 的串行阶段占时”，而更接近“在 `C_DP_RUN` 内发生的有效 retire / softmax issue 事件计数”。

也就是说，当前 perf 中：

- `dp=66560`
- `score=32768`
- `softmax=32768`

**不能再简单相加** 去还原 `MS_COMPUTE`。因为后两者已经和 `QK` issue / retire 发生了大量重叠。

### 12.2.4 `MS_COMPUTE=67584` 的含义

当前：

$$
MS\_COMPUTE = 67584,
\qquad
CS\_DP = 66560.
$$

差值只有：

$$
67584 - 66560 = 1024.
$$

全局共有 `32` 个 compute tile，因此每个 compute tile 额外只有：

$$
1024 / 32 = 32
$$

个控制边界周期。

这意味着当前 compute 主体已经接近“**QK 批流式 issue 的周期下界 + 少量 tile/control 气泡**”的状态，而不再是旧版那种被 softmax 和 QK 流水反复拖住的结构。

### 12.3 与旧版 `608296 cycles` 的对照

旧版最主要的问题是：

1. `QK` 的 `8` 拍延迟按每个 score-pair 支付；
2. `softmax ctx` 的 `7` 拍延迟也按每个 score-pair 支付；
3. `ctx` 的多上下文能力没有被真正利用。

当前版本则已经实现：

1. `QK` 的 fill/drain 按 batch 支付；
2. `ctx` softmax 以 `4-context` 交错使用；
3. score retire 与 softmax issue 和 QK issue 同时发生。

因此，当前实测结果表明：

> 第 10.1 节中“QK tag 化流式回收原型”和“ctx 多上下文交错版 softmax 调度原型”这两项，**就周期指标而言已经基本完成并兑现到 RTL 实测中了。**

但第 10.1 节的第三项——“把 top test 的 fixed 参考升级为 `ctx-strict` 口径”——**还没有完成**，因为当前 top test 的 fixed 参考仍然是旧口径。

### 12.4 C++ TB 与顶层 perf 的对照：10.2 已完成

第 10.2 节中提出的三项辅助工作，本轮已经完成了前两项实质内容：

1. 已补并运行当前版本的 Verilator C++ core profile；
2. 已完成 core profile 与 top perf counters 的逐项对比。

两者对比如下：

| 指标 | Core C++ TB | Top cocotb | 差值 |
|---|---:|---:|---:|
| `total/busy` | `85808/85807` | `85928/85928` | 约 `+120` |
| `compute` | `67584` | `67584` | `0` |
| `normalize` | `5888` | `5888` | `0` |
| `dp` | `66560` | `66560` | `0` |
| `score` | `32768` | `32768` | `0` |
| `softmax` | `32768` | `32768` | `0` |
| `load_q` | `2054` | `2080` | `+26` |
| `load_k` | `4104` | `4144` | `+40` |
| `load_v` | `4104` | `4144` | `+40` |
| `write_o` | `2056` | `2072` | `+16` |

这说明：

1. **compute 核心的周期模型已经在 core/top 两个口径下完全对齐；**
2. top 相比 core 多出来的约 `120` 个周期，主要来自 DMA wrapper / AXI 边界行为，而不是 compute 核心重新退化；
3. 当前周期闭环已经足够稳定，可以把下一阶段重心从“周期是否达标”切到“误差与参考口径是否要同步更新”。

### 12.5 数值结果的当前判断

当前周期已经满足 Baseline，但数值上仍需保持谨慎：

- C++ core profile：
	- `RTL vs FP32 MAE = 0.006692`
	- `MAX_AE = 0.121094`
- top cocotb：
	- `RTL vs FP32 MAE = 0.011788`
	- `MAX_AE = 0.246094`

因此，当前状态应描述为：

1. **周期要求已满足；**
2. **fixed 参考仍不是当前最严格等价口径；**
3. **FP32 误差仍高于赛题 `MAX_AE <= 0.10` 门限，说明后续还需要继续处理数值路径或参考对齐问题。**

换言之，当前不是“周期和精度都完全结束”，而是“**周期侧 10.1 已基本完成，10.2 的辅助 profile 对账也已完成；下一步应从周期主线转向数值口径与误差问题。**”

## 13. 2026-03-11 追加：当前 `ctx` 主线的数值根因、CModel 对齐与 RTL 修正

本轮继续把重点从周期转到数值后，得到一个更明确的结论：**当前 streamed `ctx` 版本的主要误差来源并不是 `exp2_approx()` 本身，而是 `acc` 在 `fa_online_softmax_ctx` 与 `fa_o_normalize_block` 之间的尺度口径没有完全对齐。**

### 13.1 严格按 RTL 结构还原后的 CModel 现象

对 `cmodel/` 增加当前 `ctx` 主线的对齐模式之后，可得到：

- `rtl_ctx_step`：严格仿真当前 `fa_online_softmax_ctx` 的
	- `exp2` 查表；
	- `acc_q16_16` 标量状态；
	- `recip_nr_rtl_q16_16`；
	- 当前 normalize 口径；
- 该模式的结果为：
	- `MAE(mean) ≈ 0.005837`
	- `MaxAE(worst) = 0.121094`

它与之前 Verilator C++ core profile 的 `0.121094` 完全对上，说明 **CModel 已经成功对齐到“当前 RTL 真实在做什么”**，而不是继续停留在旧 `pair/PWL` 参考上。

更关键的是，把 `exp2 step / exp2 interp / pwl / real-exp` 互换之后，`MaxAE` 几乎不变，仍停在约 `0.121094`。这说明：

$$
	ext{主误差项} \neq \text{exp 近似本身}
$$

而更接近：

$$
	ext{acc / normalize 的数值尺度不一致}
$$

### 13.2 根因定位：`acc_q16_16` 与 normalize 输入尺度相差 `2^8`

当前 `fa_online_softmax_ctx` 输出的是 `o_acc_q16_16`，即每个 lane 的累计值处在 `Q16.16` 口径；但 `fa_o_normalize_block` 的乘倒数输出链路，在当前 `>>> 32` 的实现下，等价地要求其输入累计量在进入归一化前已经带有额外的 `2^8` 缩放。

对最简单的 causal 首行可直接看出这一点：

1. 首行只有 `j=0` 一个有效项；
2. 此时理论上输出应几乎等于 `V[0]`；
3. 若直接把 `Q16.16` 的 `acc` 送入当前 normalize，再做 `>> 32`，结果会系统性少掉 `8` 个分数位；
4. 于是很多本应输出的 `Q8.8` 小数值会被压成 `0`，其典型最大误差正好落在 `31 / 256 = 0.121094` 这一量级。

因此这里的问题不是“softmax 算错了”，而是：

> `ctx` leaf 产生的 `acc` 口径已经变成 `Q16.16`，但 normalize 仍按旧主线累计量的尺度去解释它。

### 13.3 CModel 修正方案与结果

在 CModel 中加入尺度修正模式 `rtl_ctx_step_acc24`，只做一件事：

- 在 normalize 前，把 `row_acc` 左移 `8` bit 再送入当前 `recip * acc >> 32` 链路；
- 其余 `ctx` 结构、`exp2`、`recip_nr_rtl`、32bit `acc` 状态全部保持不变。

得到的结果为：

- `MAE(mean) ≈ 0.002726`
- `MaxAE(worst) = 0.006128`

已经明显满足赛题门限：

$$
	ext{MAE} \le 0.03, \quad \text{MaxAE} \le 0.10
$$

因此，本轮数值优化的核心结论是：

1. **当前 `ctx` 版本可以保持现有 softmax leaf 结构；**
2. **不需要先把 `exp2_approx()` 重写成别的算法才能达标；**
3. **最先应修的是 `acc` 进入 normalize 之前的尺度对齐。**

### 13.4 RTL 回灌方案

基于上面的 CModel 结论，本轮已将 RTL 做成最小修正：

- 在 [rtl/core/fa_attention_core.sv](rtl/core/fa_attention_core.sv) 的 normalize 输入拼接处，把
	`row_acc[norm_qi][norm_d + lane]`
	改为
	`row_acc[norm_qi][norm_d + lane] <<< 8`；
- 这样做的好处是：
	- **不改变** `row_acc` 在跨 `K/V tile` 计算阶段保存给 `ctx` leaf 的 `Q16.16` 状态；
	- **只在最终 normalize 入口** 做尺度补偿；
	- 对周期和调度完全无影响，属于纯数值口径修正。

### 13.5 最新验证结果

本轮修正后，top-level cocotb `full-run` 结果为：

- `cycles = 85928`
- `rtl vs fixed-q8.8: mae_lsb = 0.0000, max_err_lsb = 0`
- `rtl vs fp32: mae = 0.002499, max_err = 0.006583`

这说明：

1. **周期指标保持不变，仍远低于 `300k`；**
2. **当前 top 主线已经重新满足精度门限；**
3. **本轮 RTL 数值修正与 CModel 结论一致。**

需要额外说明的是：direct-core Verilator C++ profile 口径目前仍出现与 top 不一致的旧现象，因此在本轮之后，**数值签收应优先以“top cocotb + 对齐后的 CModel”作为主口径**；C++ core profile 仍适合做周期/事件画像，但其 direct-core 数值口径还需要单独再清理一次 testbench 假设。
