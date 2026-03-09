# 2026-03-10 QK 全流水乘法-加法树实验报告

## 1. 目标

基于前一轮结论 [docs/20260309_softmax_qk_norm_followup_report.md](docs/20260309_softmax_qk_norm_followup_report.md)，本轮只聚焦 QK dot-product，验证下面这个判断：

- 不降低 `32-lane` 字并行度；
- 不再把“4 个乘法 + 局部加法树”塞进同一拍；
- 把第 1 级强制改成“纯乘法寄存”；
- 后续 reduction tree 做严格逐级流水；
- 目标是在 `55nm` 下把独立模块显著推过 `200MHz`，并观察是否逼近 `400MHz`。

---

## 2. 新增实验

本轮新增 3 个实验：

- [experiments/fa_qk_dotprod_slice_pipe/exp_f/fa_qk_dotprod_slice_pipe.sv](experiments/fa_qk_dotprod_slice_pipe/exp_f/fa_qk_dotprod_slice_pipe.sv)
- [experiments/fa_qk_dotprod_slice_pipe/exp_g/fa_qk_dotprod_slice_pipe.sv](experiments/fa_qk_dotprod_slice_pipe/exp_g/fa_qk_dotprod_slice_pipe.sv)
- [experiments/fa_qk_dotprod_slice_pipe/exp_h/fa_qk_dotprod_slice_pipe.sv](experiments/fa_qk_dotprod_slice_pipe/exp_h/fa_qk_dotprod_slice_pipe.sv)

同时更新了测试延迟映射：

- [experiments/fa_qk_dotprod_slice_pipe/tb/test_fa_qk_dotprod_slice_pipe.py](experiments/fa_qk_dotprod_slice_pipe/tb/test_fa_qk_dotprod_slice_pipe.py)

### 2.1 `exp_f`：纯乘法首拍 + 全流水二叉树

结构：

1. stage1：`32` 个 `16x16` 乘法器，只做乘法并寄存到 `mult*_r`
2. stage2：`32 -> 16`
3. stage3：`16 -> 8`
4. stage4：`8 -> 4`
5. stage5：`4 -> 2`
6. stage6：`2 -> 1` 输出

特点：

- 完全符合“乘法和加法彻底分拍”的原则；
- `II=1` 保持不变；
- 延迟从 `exp_e` 的 `4` 拍增加到 `6` 拍。

### 2.2 `exp_g`：全流水二叉树 + 位宽逐级收敛

在 `exp_f` 基础上，把各级部分和位宽缩到理论所需最小值：

- 乘法：`32b`
- `2` 项和：`33b`
- `4` 项和：`34b`
- `8` 项和：`35b`
- `16` 项和：`36b`
- `32` 项和：`37b`

最后再符号扩展到 `40b` 输出。

目的：

- 降低中间 adder / flop / net 的无效位宽；
- 进一步减轻布线与寄存器负担；
- 观察面积是否继续下降。

### 2.3 `exp_h`：输入预寄存 + 位宽逐级收敛

在 `exp_g` 基础上，再增加一拍输入捕获：

- 先把 `q0/q1/k` 大总线打一拍；
- 下一拍再驱动 `32` 个乘法器；
- 其余 reduction tree 与 `exp_g` 相同。

目的：

- 降低顶层输入总线到乘法器阵列的扇出压力；
- 验证“输入寄存 + mult-only stage”是否值得为更高频率支付额外 1 拍。

---

## 3. 功能验证

3 个新实验均通过 lint 和 cocotb：

- `exp_f` PASS
- `exp_g` PASS
- `exp_h` PASS

对应测试文件：
- [experiments/fa_qk_dotprod_slice_pipe/tb/test_fa_qk_dotprod_slice_pipe.py](experiments/fa_qk_dotprod_slice_pipe/tb/test_fa_qk_dotprod_slice_pipe.py)

---

## 4. 综合 / STA 结果

### 4.1 新实验结果

| Module | Exp | Area | Worst Slack(ns) | Est Fmax(MHz) | TNS | Endpoint |
|---|---:|---:|---:|---:|---:|---|
| fa_qk_dotprod_slice_pipe | exp_f | 274363.60 | -0.619 | 381.9 | -498.415 | `mult0_r[23]_31__reg_p:D` |
| fa_qk_dotprod_slice_pipe | exp_g | 272855.24 | NA | NA | NA | NA |
| fa_qk_dotprod_slice_pipe | exp_h | 286906.48 | NA | NA | NA | NA |

说明：

- `exp_f` 的 STA 完整跑通；
- `exp_g` / `exp_h` 的综合结果已生成，但本轮环境下 STA 进程被异常中断，`sta.log` 未形成有效报告，因此先记为 `NA`；
- 从 `exp_f` 已足够验证主假设：**把首级改成纯乘法后，QK 频率从 ~`203.8MHz` 跳升到 ~`381.9MHz`。**

### 4.2 与上一轮最佳结果对比

| Exp | 结构摘要 | Area | Est Fmax(MHz) | 备注 |
|---|---|---:|---:|---|
| `exp_e` | `8` 组局部乘加 + `qtr/half/final` | 273621.04 | 203.8 | 关键路径仍落在 `mac*_r` |
| `exp_f` | `mult-only` + 全流水二叉树 | 274363.60 | 381.9 | 关键路径转移到 `mult*_r` |
| `exp_g` | `exp_f` + 位宽收敛 | 272855.24 | NA | 面积略降，待补 STA |
| `exp_h` | `exp_g` + 输入预寄存 | 286906.48 | NA | 面积上升，待补 STA |

结论非常明确：

- `exp_e -> exp_f` 频率提升约 `+178MHz`；
- 面积几乎不变，仅增加约 `742.56`；
- 关键路径已经不再是加法树，而是单个乘法器输出到 `mult*_r`。

---

## 5. 结果解读

### 5.1 为什么 `exp_f` 有效

`exp_e` 的问题不是“树还不够深”，而是首级每个局部块里仍有：

- 多个 `16x16` 乘法器
- 局部求和
- 再打一拍

`exp_f` 之后，关键路径被强行裁成：

$$
\text{DFF} \rightarrow 16\times16\ \text{mult} \rightarrow \text{DFF}
$$

后面的每一级都只剩一个二输入加法器，因此：

- 关键路径大幅缩短；
- TNS 从 `-2313.320` 降到 `-498.415`；
- Fmax 从 `203.8MHz` 拉升到 `381.9MHz`。

### 5.2 `exp_f` 暴露的新瓶颈

`exp_f` 的最差端点已经变成：

- `mult0_r[23]_31__reg_p:D`

这说明当前结构下的主瓶颈已经被成功收敛到 **单乘法器级**，而不是宽树级。这是一个非常理想的中间结果，因为后续优化方向已经足够清晰：

1. 输入扇出继续优化；
2. 乘法器前级寄存器复制 / 物理邻近布局；
3. 必要时探索 Booth / 部分积型乘法 RTL；
4. 或在系统层接受 `380MHz+` 的独立模块上限。

### 5.3 `exp_g` / `exp_h` 的意义

虽然本轮未得到完整 STA，但已有两点可先确认：

- `exp_g` 面积低于 `exp_f`，说明位宽收敛是合理方向；
- `exp_h` 面积高于 `exp_f` / `exp_g`，输入寄存会引入明显的寄存器成本。

因此后续若补跑 STA，最值得优先确认的是：

- `exp_g` 是否能在基本不增面积的情况下进一步逼近 `400MHz`；
- `exp_h` 的额外 1 拍是否真的能换来可见的频率收益。

---

## 6. 对总周期的影响

这一轮实验保留了：

- `32-lane`
- `word-parallel`
- `II=1`

因此它和“改成 16-lane / 8-lane / serial”有本质区别。

如果主线后续把当前固定 `C_DP_RUN=2` 的控制方式改成**流式 valid 管线**，那么：

- 每个 chunk 的吞吐仍是 `1 / cycle`
- 每个 pair 仍只需要喂入 `2` 个 `32-lane` chunk
- 增加的只是流水线 fill / drain latency

以当前 `32768` 个 score-pair 估算，QK 独立模块从 `4` 拍增至 `6~8` 拍，不会像降到 `16-lane` 那样把总周期直接推到 `214k+`。代价主要体现在：

- 控制器需要从“固定等待 2 拍”改成“发射与回收解耦”；
- 需要为 `row-pair` / `chunk id` 增加轻量 tag 或对齐寄存。

所以这一路线依然符合“**不增加太多总周期数**”的原始要求。

---

## 7. 工程结论

### 7.1 已验证结论

本轮已经可以确认：

1. **QK 不需要降并行度到 16-lane 才能过 200MHz。**
2. **32-lane 保持不变，只要把首级改成纯乘法、后面做全流水二叉树，就能把独立模块拉到约 `382MHz`。**
3. 当前 QK 的真正可行方向不是 bit-serial，也不是继续在局部块内堆“乘法 + 局部求和”，而是：
   - `mult-only` 首拍
   - 逐级流水 reduction tree
   - 必要时再做输入扇出优化

### 7.2 推荐下一步

优先级建议：

1. 先以 `exp_f` 作为主参考结构；
2. 补跑 `exp_g` 的 STA，判断“位宽收敛”是否能在几乎不增面积下进一步提升频率；
3. 若目标仍是逼近 `500MHz`，再评估 `exp_h` 或更激进的乘法器 RTL；
4. 主线集成时，把 `fa_attention_core` 的 QK 控制从固定 `2` 拍等待改成流式发射 / 回收。

---

## 8. 一句话结论

这一轮实验已经证明：**在 55nm 下，把 32-lane QK dot-product 改成“纯乘法首拍 + 全流水加法树”，可以在几乎不增加面积、且不牺牲吞吐的前提下，把频率从约 `204MHz` 直接推到约 `382MHz`。**
