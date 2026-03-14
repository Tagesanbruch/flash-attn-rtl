# 2026-03-15 INT8/FP8 Bootstrap 实现与验证报告

## 1. 本轮目标

按本轮指令，完成以下闭环：

1. 建立并切换实验分支；
2. 产出 INT8/FP8 架构到实现的启动分析；
3. 在 `experiments/int8` 与 `experiments/fp8` 落地关键节点模块；
4. 补齐 cocotb 验证并形成可复现结果。

## 2. 分支与文档

分支：

- `exp/int8-fp8-bootstrap`

启动分析文档：

- `docs/20260315_int8_fp8_architecture_and_bootstrap_plan.md`

## 3. 新增模块与测试

### 3.1 INT8

- `experiments/int8/fa_int8_mac_lane/base/fa_int8_mac_lane.sv`
- `experiments/int8/fa_int8_mac_lane/tb/test_fa_int8_mac_lane.py`
- `experiments/int8/fa_int8_dotprod16/base/fa_int8_dotprod16.sv`
- `experiments/int8/fa_int8_dotprod16/tb/test_fa_int8_dotprod16.py`

功能定位：

1. `fa_int8_mac_lane`：单 lane 的 `int8 x int8 -> int32` 乘加基元；
2. `fa_int8_dotprod16`：16 路 int8 点积聚合。

### 3.2 FP8

- `experiments/fp8/fa_fp8_e4m3_to_fixed16/base/fa_fp8_e4m3_to_fixed16.sv`
- `experiments/fp8/fa_fp8_e4m3_to_fixed16/tb/test_fa_fp8_e4m3_to_fixed16.py`
- `experiments/fp8/fa_fp8_dotprod8_fixed/base/fa_fp8_dotprod8_fixed.sv`
- `experiments/fp8/fa_fp8_dotprod8_fixed/tb/test_fa_fp8_dotprod8_fixed.py`

功能定位：

1. `fa_fp8_e4m3_to_fixed16`：E4M3 解码到 Q4.11；
2. `fa_fp8_dotprod8_fixed`：8 路 FP8(经 Q4.11) 点积并输出 Q8.11。

## 4. 验证命令与结果

执行命令：

```bash
make -C experiments verif MOD=int8/fa_int8_mac_lane EXP=base
make -C experiments verif MOD=int8/fa_int8_dotprod16 EXP=base
make -C experiments verif MOD=fp8/fa_fp8_e4m3_to_fixed16 EXP=base
make -C experiments verif MOD=fp8/fa_fp8_dotprod8_fixed EXP=base
```

结果汇总：

1. `int8_mac_lane`：PASS，`samples=5000`, `mismatches=0`；
2. `int8_dotprod16`：PASS，`samples=4000`, `mismatches=0`；
3. `fp8_e4m3_to_fixed16`：PASS，`samples=5000`, `mismatches=0`；
4. `fp8_dotprod8_fixed`：PASS（修复后），`samples=3000`, `mismatches=0`。

## 5. 关键问题与修复

### 5.1 问题现象

`fp8_dotprod8_fixed` 初次回归失败：`mismatches=183/3000`。

### 5.2 根因

内部累加位宽不足：

- 单项乘积上界约为 $32767^2 \approx 1.07\times 10^9$；
- 8 路累加上界约为 $8.59\times 10^9$，超过有符号 32 位上限 $2.147\times 10^9$。

因此 32 位 `sum_q8_22` 发生溢出，导致与参考模型不一致。

### 5.3 修复

文件：

- `experiments/fp8/fa_fp8_dotprod8_fixed/base/fa_fp8_dotprod8_fixed.sv`

改动：

1. `prod_q8_22` 与 `sum_q8_22` 从 32 位扩展到 40 位；
2. 乘法显式使用有符号乘法，避免隐式宽度/符号歧义；
3. 保持输出接口不变，最终仍输出 `o_dot_q8_11`。

修复后复测：`mismatches=0`。

## 6. 当前结论

1. INT8/FP8 bootstrap 第一批 key nodes 已完成并通过随机回归；
2. FP8 路径已验证“解码 + 小规模点积”链路可用；
3. 位宽规划是后续阵列化/MMA 化时的首要约束，应优先做统一的数值预算表。

## 7. 下一步建议

1. 将 `int8_dotprod16` 组合为可参数化 tile（支持 lane 数、累加树深度配置）；
2. 在 FP8 路径增加可选舍入模式与饱和策略，并补边界向量集（Inf/NaN/Denorm）；
3. 定义统一 MMA 微接口（`valid/ready + a/b/acc + scale`），对齐后续 TensorCore 风格演进。
