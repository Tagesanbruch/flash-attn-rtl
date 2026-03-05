# 3 算法定点化设计与在线 Softmax 核心

传统的 Transformer 在计算 $Softmax\left(\frac{QK^T}{\sqrt{d}}\right)V$ 时依赖于全局的 `exp()` 与 `sum()`。然而在有限算力设备中，我们无法承载全量浮点 `exp`，也不能一次性将所有的 Attention Scores 放进显存然后再归一。因此我们采用了一种纯定点、在线计算、并且由硬件高度优化的逐行处理算法。

## 3.1 核心定点化流水线总体考量

赛题规定并基准化测试的是输入为 **Q8.8 定点数**的流处理，这意味着每个数据元在系统中以 16 位补码的形式游走。

**核心问题与定点困境：**
1. **点积累加溢出（Overflow of MAC）**：$N$ 次加法累加会导致定点数的动态范围急剧增加。
2. **指数逼近截断（Truncation in Exponents）**：在遇到大负数进行 $\exp(-x)$ 操作时会导致数值快速逼近 0。
3. **倒数无穷发散（Divergence of Reciprocal）**：当分母（累进归一化因子）受上述条件变得极小或为 0 时发生 $1/0 \rightarrow \infty$ 崩溃。

## 3.2 累加位宽与数值防灾设计 (Numerical Disaster Prevention)

### 3.2.1 第一道防线：64 位冗余累加器
在 `C_DP_RUN` 进行 $QK^T$ 点积计算的过程中，单纯的 $16\text{-bit} \times 16\text{-bit}$ 会产生 $32\text{-bit}$ 的中间乘积结果，当我们累加比如 $C=64$ 及以上长度的一整个通道向量后，32位很可能是会溢出的。在 RTL 中我们定义 `row_acc` 和所有关于统计项 `m_val`, `l_val` 等全采用了极高冗余的寄存器宽度（如内部 32位 甚至 64位）。

### 3.2.2 第二道防线：减偏缩放策略 (Shift-based Subtraction)
对于任何新处理的 K-Tile，我们记录本 Tile 产生的最高打分（Score Max），通过 $S' = S - Max$ 来强迫最大的得分为 0或负数。
在纯定点中这能彻底规避正向指数爆炸（$e^{S} \rightarrow \infty$），因为所有的 $\exp$ 被转为了 $\exp(\text{negative}) \le 1$。
RTL中的减偏：
```systemverilog
// x_diff 是当前得分与其运行中最大值 m_val_q 的差，一定具有大负值概率
assign p_pre_exp = score_q - m_new_val_q; 
```

### 3.2.3 第三道防线：下溢守护（Underflow Safeguard) —— P0核心达标指标
这个步骤正是我们对 P0 设计中数值崩溃进行了根本性修补的 RTL 真相：

由于 $P = \exp(S')$ 全为分数，经过截断或极度缩小后可达 0，此时新加入的归一化系数 $L_{new}$ 会等于：
$$ L_{new} = e^{m_{old} - m_{new}} L_{old} + e^{S'} $$
若该算式因精度过低被定点逻辑抹除为 $0$，那么它去求倒数（$1/l\_new\_val0$）就会产生致命硬件错误（除零爆点，变成全是 0xFFFFFFFF 或 `X`）。
> **RTL 实现见 `fa_attention_core.sv` 中的硬守护**：
```systemverilog
    // P0 - 数值稳定：当分母累加至0时必须给予1保障其继续收敛，避免被0除导致全局污染
    logic [31:0] l_new_safe;
    assign l_new_safe = (l_new_val0 == 32'd0) ? 32'd1 : l_new_val0;
```
这一句硬编码的 Multiplexer 成功稳定住了极低输入下的浮点退化测试集。MAE 依然稳定于 0.000971 的金标准范围内。

## 3.3 非线性算子近似（PWL与NR）

由于无法使用浮点的 DSP 算子，在硬件中我们通常使用**片内查表（LUT）合并线性差值**（PWL，Piece-Wise Linear）或**牛顿-拉弗森法（Newton-Raphson）**进行近似。

### 3.3.1 指数近似 PWL (Piece-Wise Linear Exponent)
原设计 `fa_exp_pwl_8seg_q1_15.sv` 中使用了硬编码的 8 分段折线。其参数如斜率（Slope）与截距（Intercept）基于泰勒展开或者统计算法提前获得，被定死在 ROM 类似的 `case` 语句块中：
```systemverilog
// 截取自 RTL
always_comb begin
    case (seg_idx)
        3'd0: begin slope = ...; intercept = ...; end
        // ... (直至 3'd7)
    endcase
end
```
**P1 带宽扫描的衍生讨论**：本近似算子的分段数量 $M$（原默认 $M=8$）成为我们在 P1 实验中重点探索的架构参数空间。虽然在现有验证 RTL 实体中此值仍然固定（为确保 P0 不受影响），但我们的 CModel 中已经全面展开了多配置参数扫描用于论证 $M=1$ 至 $M=16$ 对于面积（LUT）和带宽的置换潜能。

### 3.3.2 倒数近似 NR (Newton-Raphson Division)
系统采用了 $1/L_{new}$ 的 Newton-Raphson (NR) 迭代除法逼近模块 `fa_recip_nr_q16_16`，取代长周期除法器 IP。
通过初始估测器加上几次乘加（$x_{n+1} = x_n(2 - d \cdot x_n)$），只需三阶即可快速收敛。
在 RTL 层级，因为除法器永远是数据流中的卡点（Bottleneck），其消耗时钟周期的多寡以及其实例化流水级的深浅决定了我们的 `C_SOFTMAX_PREP` 能多快向 `C_UPDATE_O` 切入，进而决定着最终的时钟利用率。对于此核心，采用基于移位的规格化算法保证了哪怕是最复杂的非线性部分依然保持着常数时钟内推演并与乒乓预取等深。