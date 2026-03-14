# 2026-03-15 INT8/FP8 架构到实现启动文档（分支 bootstrap）

## 1. 目标

在不打断当前 BF16/FP16 主线的前提下，建立 INT8/FP8 的可演进技术底座：

1. 明确架构层接口（MMA 微操作语义）；
2. 落地关键节点模块（实验级）；
3. 形成可运行验证闭环（cocotb）；
4. 给出数量级评估（吞吐、带宽、阵列数量、资源量级）。

## 2. 问题规模与统一口径

默认参数：`S=256, D=64`。

- pair 数：

$$
N_{pair}=S\times S=65,536
$$

- SDPA 主体 MAC 数（QK + PV）：

$$
N_{MAC}=2\times S\times S\times D=8,388,608
$$

- OPS（`1 MAC = 2 OPS`）：

$$
N_{OPS}=16,777,216
$$

- 外存流量（16-bit 路径历史口径）：`576KB`。

INT8/FP8 若改为 8-bit 数据面，在同 shape 下理论流量可近似减半到 `288KB`（不含 metadata/scale）。

## 3. 架构分层建议

## 3.1 调度层（先稳定）

定义统一微操作：

- `MMA(m, n, k, in_dtype, acc_dtype, scale_policy)`

其中：

- `in_dtype`：`INT8` / `FP8(E4M3/E5M2)`
- `acc_dtype`：`INT32` / `FP16` / `FP32`
- `scale_policy`：`none/per_tensor/per_block`

优先把调度接口固定，再替换执行体。

## 3.2 执行层（渐进替换）

建议三阶段：

1. `vector lanes`（当前实验目标）
2. `small MMA tile`（8x8 或 16x8）
3. `multi-core cluster`（是否 4 core 复制看 PPA）

## 3.3 数据层（量化与缩放）

- INT8：`int8 x int8 -> int32`，输出重标定
- FP8：先从 `E4M3 + FP32 accum` 启动
- 缩放策略先从 `per-tensor` 起步，随后评估 `per-block`

## 4. 数量级推导（用于定目标）

## 4.1 吞吐目标

如果希望达到 `X attns/s/GHz`，需要满足：

$$
\text{cycles}\le \frac{10^9}{X}
$$

例如：

- `X=2,000` 时，`cycles <= 500,000`
- `X=5,000` 时，`cycles <= 200,000`

## 4.2 lane 数量粗估

若 pair 级周期模型为：

$$
C_{pair}\approx \left\lceil\frac{64}{P_{qk}}\right\rceil + \left\lceil\frac{64}{P_{pv}}\right\rceil + C_{ovh}
$$

当 `P_qk=P_pv=16` 且 `C_ovh\approx 2` 时：

$$
C_{pair}\approx 4+4+2=10
$$

总周期约：

$$
65,536\times 10 + C_{other} \approx 655,360 + C_{other}
$$

说明仅 16-lane 仍不够激进，需要更深重叠或更高 lane 并行。

## 4.3 “4 个低精度 tensor core”是否必要

短期不必要直接复制 4-core；建议先测：

1. 单 core（vector/MMA tile）性能与面积；
2. 双 core 扩展收益；
3. 再决定是否到 4 core（避免线性堆硬件）。

## 5. 本轮落地模块（实验级）

INT8 路径：

1. `fa_int8_mac_lane`：`int8 x int8 + int32`
2. `fa_int8_dotprod16`：16-lane dot，输出 int32

FP8 路径（E4M3）：

1. `fa_fp8_e4m3_to_fixed16`：FP8 解码到有符号 fixed16（Q4.11）
2. `fa_fp8_dotprod8_fixed`：8-lane FP8 dot（经 fixed 解码后乘加）

这些模块用于验证“数据面与验证面可跑通”，不是最终最优 PPA 版本。

## 6. 验证策略

1. 模块级 bit-check（INT8 路径可做到严格位对齐）
2. FP8 路径采用数学参考（允许 NaN/Inf 边界先做行为一致）
3. 每个模块至少 2000~5000 随机样本

## 7. 后续里程碑

1. M1：模块级通过（本轮）
2. M2：拼接成最小 tile engine（QK 或 PV 单侧）
3. M3：引入缩放策略（per-tensor -> per-block）
4. M4：评估小 MMA tile 与 vector 的 PPA 交叉点

## 8. 当前结论

1. INT8/FP8 路线应先固定调度接口，再替换执行体；
2. FP8 不建议 LUT 化通用 MAC，LUT 主要用于函数近似；
3. 本轮先建立可运行实验模块与验证，用于下一步系统集成。