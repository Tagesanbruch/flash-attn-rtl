# 2026-03-15 FP8 IP 与 Q8.8 主线/题意对齐清单

## 1. 对齐目标

在进入全核验证前，确保 FP8 路径与现有 Q8.8 主线在以下维度严格对齐：

1. 控制面语义（寄存器位定义、启动/忙闲/完成行为）；
2. 数据面边界（shape、stride、tile 顺序、buffer 访问时序）；
3. 性能口径（cycle 统计与 perf counter 定义）；
4. 题意约束（精度、时延、吞吐、接口协议）。

## 2. 必做对齐项

### 2.1 寄存器与状态机

1. `start/busy/done` 时序与 Q8.8 语义一致；
2. 配置寄存器读写权限、默认值、sticky 位与 W1C 语义一致；
3. round/sat/scale/mode 位定义与主线命名保持统一。

### 2.2 数据路径与 tile 调度

1. Q/K/V 的 tile 扫描顺序与 Q8.8 主线一致；
2. score/softmax/ctx 的中间缓存命名与生命周期一致；
3. backpressure 与握手行为在 flush/bubble 场景与主线一致。

### 2.3 性能计数口径

1. compute/dp_run/score_done/softmax_prep 计数定义复用主线口径；
2. cycle 统计起止条件与 Q8.8 回归完全一致；
3. 在同 shape 下输出可直接横向比较。

### 2.4 精度与题意指标

1. 与 golden 的误差口径（MAE/MaxAE）保持一致；
2. corner case（NaN/Inf/Subnormal/overflow）策略可配置且可验证；
3. 所有题意约束项对应到可观测测试指标。

## 3. 全核验证前置门槛

1. 模块级：QK/softmax/PV/mma 单元全部 PASS；
2. 子系统级：tile 调度 + 控制面 + perf counter PASS；
3. 顶层级：与现有 `fa_attention_ip_top` 回归框架对接通过；
4. 报告级：输出“对齐矩阵 + 指标差异 + 残余风险”。

## 4. 下一步执行建议

1. 先做寄存器语义对齐并接入 FP8 控制位；
2. 再做 tile 调度与 perf counter 口径对齐；
3. 最后进入全核回归（含题意约束核验）。
