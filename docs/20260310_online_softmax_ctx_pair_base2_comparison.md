# 2026-03-10 Online Softmax `ctx` / `pair` / `base2` 实现对比说明

## 1. 目的

本文用于把当前仓库里三类 online softmax 相关实现的**接口形态、微结构差异、已有时序数据、以及对 `fa_attention_core` 调度的影响**统一梳理清楚，避免后续报告中把“独立模块最优结果”和“当前主线实际在用结构”混为一谈。

对比对象包括：

1. `fa_online_softmax_pair`
2. `fa_online_softmax_ctx`
3. `fa_online_softmax_base2`

<!-- 图1：三种 online softmax 实现关系图 -->
<!-- 图2：三种实现的输入/输出接口对比图 -->

---

## 2. 三个模块当前在仓库中的位置

### 2.1 `fa_online_softmax_pair`

- 当前活动 RTL：已从主线目录移走，保存在 [useless/rtl_unused/20260310_archived/fa_online_softmax_pair.sv](useless/rtl_unused/20260310_archived/fa_online_softmax_pair.sv)
- 历史角色：主线 `fa_attention_core` 中的双行、向量级 online softmax + PV 累加叶模块
- 特点：接口最贴近旧主线调度；一次同时处理两个 query row，并直接更新整条 `D=64` 向量累计值

### 2.2 `fa_online_softmax_ctx`

- 当前活动 RTL： [rtl/core/fa_online_softmax_ctx.sv](rtl/core/fa_online_softmax_ctx.sv)
- 来源：`experiments/fa_online_softmax_ctx/exp_d`
- 当前角色：已重新接回主线，并作为 `fa_attention_core` 当前 softmax 更新的底层参考实现
- 特点：单 score / 单 value 标量更新单元，内部有 `4-context interleave + forwarding + 4~5 stage pipeline`

### 2.3 `fa_online_softmax_base2`

- 实验 RTL：
  - [experiments/fa_online_softmax_base2/base/fa_online_softmax_base2.sv](experiments/fa_online_softmax_base2/base/fa_online_softmax_base2.sv)
  - [experiments/fa_online_softmax_base2/exp_a/fa_online_softmax_base2.sv](experiments/fa_online_softmax_base2/exp_a/fa_online_softmax_base2.sv)
- 当前角色：历史实验候选，不是当前主线候选
- 特点：把自然底 `exp` 改成 `exp2` 近似，但仍然是单 context、单标量状态机

---

## 3. 接口与微结构差异

### 3.1 `pair`：最贴近旧主线的数据通路

`fa_online_softmax_pair` 的核心特征是：

1. 一次处理两个 query row
2. 输入是 `score0/score1 + m/l + 整条 acc 向量 + 整条 v_row`
3. 输出直接给出两个 row 的新 `m/l/acc`
4. `acc` 更新在模块内部以 `D=64` 全向量组合方式完成

它的优点是**非常贴合旧版 `fa_attention_core` 调度**：

- `C_SCORE_DONE` 后一拍即可进入 softmax 组合更新
- 不需要给每个 `D` lane 分别做发射/回收
- 不需要额外的 `ctx_id` / tag 回收结构

但问题也很明显：

- `m/l/acc` 是反馈环；
- `acc` 又是 64 维向量一起更新；
- 指数、缩放、向量乘加和状态回写全部压在一起；
- 因而它更像“**系统调度友好，但 leaf 时序很重**”的实现。

### 3.2 `ctx`：面向 500MHz 的标量流水版本

`fa_online_softmax_ctx` 的核心特征是：

1. 单次只处理一个 `(score, value)` 标量样本
2. 通过 `i_ctx_id` 支持最多 `4` 个上下文交错
3. 内部把 `max/diff/exp/l-acc update/writeback` 拆成多拍
4. 增加 `state forwarding`，避免同一 context 紧邻发射时读到旧状态

它的优点是：

- recurrence datapath 被明确切开；
- 独立模块已经在 `500MHz` 下得到正 slack；
- 是当前 softmax 路径里**唯一已经明确证明能过 500MHz 的实现族**。

但它的代价也同样清楚：

- 它不是向量级接口，而是标量级接口；
- 若要用于 `D=64` 的主线，就必须在 core 侧决定“按 lane 复制多少份 / 如何发射 / 如何回收”；
- 所以它并不是一个可以直接无代价替换 `pair` 的 drop-in leaf。

### 3.3 `base2`：方向验证过，但不是近期主线候选

`fa_online_softmax_base2` 的核心思想是：

1. 用 `exp2` 近似替代旧 `exp`
2. 保持标量 online softmax 递推
3. 重点验证“base-2 指数”这一数学/硬件方向是否比原始实现更轻

它的结论是：

- 相比旧 `fa_online_softmax_update` 有一定改善；
- 但仍然只在 `~206-210MHz` 量级；
- 与 `ctx` 相比差距很大。

因此 `base2` 更适合作为**早期方向验证**，而不是当前主线恢复对象。

<!-- 图3：pair / ctx / base2 三种 recurrence 切分方式对比图 -->
<!-- 图4：ctx 的 4-context interleave 与 forwarding 时序图 -->

---

## 4. 已有数据汇总

### 4.1 模块级 STA / 综合数据

| 实现 | 版本 | 面积 | Worst Slack(ns) | 估算频率(MHz) | 备注 |
|---|---|---:|---:|---:|---|
| `fa_online_softmax_base2` | `base` | `20719.16` | `-2.756` | `210.3` | 来自 [docs/20260306_baseline_optimization_experiment_results.md](docs/20260306_baseline_optimization_experiment_results.md) |
| `fa_online_softmax_base2` | `exp_a` | `21078.12` | `-2.860` | `205.7` | 同上 |
| `fa_online_softmax_ctx` | `exp_c` | `26433.68` | `+0.105` | `527.6` | 来自 [docs/20260309_softmax_qk_norm_followup_report.md](docs/20260309_softmax_qk_norm_followup_report.md) |
| `fa_online_softmax_ctx` | `exp_d` | `27216.28` | `+0.135` | `536.2` | 当前最佳 |
| `fa_online_softmax_pair` | 当前 archived 版本 | — | — | — | 没有独立完成且保留为稳定直接 STA 数据 |

### 4.2 系统级使用含义

| 实现 | 与当前 core 的接口匹配 | 对调度改动量 | 对模块频率 | 对系统周期的直接风险 |
|---|---|---|---|---|
| `pair` | 高 | 小 | 弱 | 小，因其本来就是旧主线接口 |
| `ctx` | 低 | 大 | 强 | 中到高，取决于是否做 context-aware issue/retire |
| `base2` | 低 | 中 | 弱 | 中，但没有 500MHz 价值 |

---

## 5. 当前主线恢复为什么选择 `ctx`

当前恢复 `ctx`，不是因为它已经自动解决了系统周期问题，而是因为：

1. `pair` 没有做出像 `ctx/exp_d` 那样的独立 500MHz 闭环；
2. `ctx/exp_d` 是已有实验里 softmax 最明确、最可复用的高频实现；
3. 报告层面需要把“当前 RTL 在使用什么 softmax 结构”与“已有最佳 softmax 结果来自什么实现”重新统一起来。

因此，本轮采取的策略是：

- 主线先切回 `ctx` 家族；
- 在 `fa_attention_core` 内部用按维复制的方式接通功能；
- 先保证回归重新通过；
- 再把“系统周期为何仍高”作为调度级问题单独分析。

---

## 6. 当前切回 `ctx` 后的最新系统现象

当前主线切回 `ctx` 并重新跑完 cocotb 后，观察到：

- `fa_online_softmax_ctx` 单模块回归通过；
- `fa_attention_core` 回归通过；
- `fa_attention_ip_top` 回归通过；
- 但顶层 perf counters 读回：
  - `cycles = 608296`
  - `cs_dp_run_cycles = 327680`
  - `cs_softmax_prep_cycles = 229376`

这说明两件事：

1. **`ctx` 作为 leaf 是可工作的**；
2. **当前 core 对 `ctx` 的接法仍然是“功能接通”，不是“吞吐最优接通”**。

换言之，`ctx` 的高频潜力并没有自动转化成系统级低周期。真正要把 `ctx` 的优势兑现出来，还需要：

- 在 `fa_attention_core` 中显式引入 row/context 的在途管理；
- 把 softmax 发射与结果回收解耦；
- 避免当前这种“每个 score-pair 都完整等待 `ctx` 流水线回收”的用法。

<!-- 图5：切回 ctx 后的顶层 perf counters 摘要图 -->
<!-- 图6：当前 core 中 ctx 发射/回收节奏示意图 -->

---

## 7. 建议结论

1. **若目标是主线恢复高频潜力，优先保留 `ctx/exp_d` 这一家族。**
2. **若目标是最小改动维持旧周期口径，`pair` 的接口更顺手，但它并没有给出 500MHz 级别的独立证据。**
3. **`base2` 当前不应再作为主线候选。**
4. 后续真正要做的不是在 `pair/ctx/base2` 三者之间继续摇摆，而是：
   - 在 softmax 侧把 `ctx` 的多上下文流水思想真正吸收到 `fa_attention_core` 调度；
   - 在 QK 侧把 `exp_h` 的长流水也做成可被 system-level overlap 隐藏的发射/回收结构。
