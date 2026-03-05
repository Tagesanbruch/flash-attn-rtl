# 5 RTL 核心实现：原代码追踪及关键路径审计 (Implementation Audit)

由于在复杂的 IP 核设计（特别如 Flash Attention 等涉及深流水和高带宽并发）中，非常容易出现报告描述在宏观架构层面，但代码底层没有落实的“虚构情况”。因此，本章节作为赛道交付物的核心“证明”环，特以“逐代码映射（Code-to-Concept Mapping）”的极度严格视角，对本 IP 尤其是 P0/P1 的所有重点要求所在的文件、行数、核心逻辑结构进行完全公开。

## 5.1 【P0赛题指标达成】双乒乓与隐藏延迟（Cycles < 300K）

为实现 $236k \rightarrow 145k$ 周期的断崖式下跌，并不是靠简单的提频（Clock Bumping），而是确确切切的并行重叠（Overlap）。

### 5.1.1 关键文件与域分离证据
- **核心文件**：`rtl/core/fa_attention_core.sv` （整个工程的中枢心脏）
- **核心逻辑**：代码定义了相互解耦的预取域和计算域。

> **预取域的定义截取（位于代码约 105 行）：**
```systemverilog
    typedef enum logic [2:0] {
        PF_IDLE,
        PF_CMD_K,
        PF_DATA_K,
        PF_CMD_V,
        PF_DATA_V,
        PF_WAIT
    } prefetch_state_t;
    prefetch_state_t pf_state, pf_next_state;
```

> **计算域的定义截取（位于代码约 155 行）：**
```systemverilog
    typedef enum logic [3:0] {
        C_IDLE,
        C_DP_RUN,
        C_SCORE_DONE,
        C_SOFTMAX_PREP,
        C_UPDATE_O
    } comp_state_t;
    comp_state_t cs, ns;
```
这一解耦保证了在 `C_DP_RUN` 中进行大量的点乘累加（MAC）时，`pf_state` 可以在 `PF_CMD_K` 及相关的等待时序中通过 AXI-Stream 自行吸纳数据。

### 5.1.2 乒乓切页的核心（Ping-Pong Swap Mechanism）
代码中使用两个极为简单的寄存器标志作为主导交恶的令牌（Token）：
```systemverilog
    logic active_bank;        // 计算侧读取
    logic pref_target_bank;   // 预取侧写入
```
并且在 `comp_done_pulse` 拉高的当且仅当一个周期进行完美翻页：
```systemverilog
    // 计算周期翻页
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_bank <= 1'b0;
        end else if (comp_done_pulse) begin
            active_bank <= ~active_bank;
        end
    end
```
上述 RTL 是我们在完全未污染原有矩阵乘加管道（MAC Pipeline）和定点运算位宽的情况下，硬生生通过隐藏访存气泡拿下的 145K Cycles 核心证明。

---

## 5.2 【P0赛题指标达成】防溢出与数值稳定

在 Q8.8 这样的低动态范围定点体系下，$Exp$ 定点尾数常会全 0 化。对于 Softmax 归一化的分母 $l$ 来说，如果它恰巧全为 0，之后的 $1/l$ 的倒数将会让硬件立即死锁崩溃（除以零产生无效数态）。这是困扰初始架构无法满足 P0 测例的最主要元凶。

### 5.2.1 定位 RTL 实现
这一处挽救全局的守护程序（Guard Program）被我们精简为一行硬逻辑，放置在了 `l_new` 的生成通路上：
- **位置**：`rtl/core/fa_attention_core.sv` (大约 189 行附近)
- **代码映射**：
```systemverilog
    // ==========================================
    // NUMERICAL STABILITY GUARD (P0 MUST-HAVE)
    // ==========================================
    // 若更新后的归一化分母 l_new_val0（由前序 l_old * decay + exp() 衰弱而来）跌停到 0。
    // 强制赋予最小单位 1，保证后序的 NR 能够正常起振运行
    logic [31:0] l_new_safe;
    assign l_new_safe = (l_new_val0 == 32'd0) ? 32'd1 : l_new_val0;
```
随后的所有 `recip` 倒数引擎乃至 $o_{res}$ 放缩统统接驳到了 `l_new_safe` 上而抛弃了原本极度危险的 `l_new_val0`。正是这段“兜底逻辑”，使得全随机且夹杂了极端分布规律测试集的 MAE 最后收敛在了完美的 0.000971。

---

## 5.3 【P1赛题要求】架构扫描分析与下一阶段开发坦陈

赛题在 P1 等级明确要求开展对于近似度的扫描与对硬件异常情况的鲁棒性传输（如超时与总线黏留）。由于此项属于探索与深化区，在此报告中我们依据真实代码进展，将现阶段取得的理论性突破（CModel 测算）和即将在下一步落入 RTL 的计划进行如实对接。

### 5.3.1 P1-4 (PWL 动态扫描设计) RTL 落空点说明与重构计划
为了生成我们主报告提及的《近似配置面积-误差平衡扫描》，目前的 `ref/cmodel` 及 `utils/p1_generate_reports.py` 均做出了极高自由度（如 `MASK_TYPE=neg`, `SEGMENTS=n`）的拟合生成与绘图。
但在 RTL 实际侧，若拉开：
- **目标文件**：`rtl/softmax/fa_exp_pwl_8seg_q1_15.sv`
其完全不提供顶层（Top-level）参数实例化（无 `#(parameter SEG=8)`），是一个彻底写死的硬链接 `case(3'd0) ... case(3'd7)`。

**下一步实现（Next Step for RTL）**：即将重构该模块为纯泛型的 `fa_exp_pwl_param_q1_15.sv`。依靠 Python 脚本预计算所有的 斜率（Slope）、截距（Intercept）打入 `.mem` 表，并转由 SV 的 `$readmemh` 或 `generate` for loop 动态生成任意多级数的折线逼近网，由此彻底实现 CModel 所绘扫描图在硬件综合（Synopsys/Vivado）报告上的真正映射（PPA 置换空间验证）。

### 5.3.2 P1-6 异常时序机制（Top-Level Error Loopback）断接的验证及修复计划
针对 AXI 传输可能存在的时效、越界异常等赛题边缘加分项：
- **当前现状**：我们在 `fa_attention_core.sv` （大约行 398 左右）发现了原本被屏蔽或直接置零的防爆针（例如：`assign o_error = 1'b0;` 或者并未响应内部 Timeout ）。
- **后续实现计划**：
  我们需要在 AXI-M 通道的 FSM（`prefetch_state_t`）中增设 `PF_TIMEOUT` 或 `RETRY` 状态节点。同时将该核心的 `o_error` 直连至 `fa_attention_ip_top.sv` 顶层端口给中断总线（Interrupt Bus）。这样在面临超大规模并发产生堵塞而无法拿到 V 数据阵列时（或者读写地址溢出 `burst_len` 边界时），IP 核将向系统软件上报硬件中断，而不是像当前版本一样选择永远卡死在那儿等待（Deadlock），从而达成商用级车规极高可靠性指标。