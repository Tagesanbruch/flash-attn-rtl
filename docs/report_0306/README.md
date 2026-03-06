# FlashAttention Baseline 报告（0306）

本目录用于承接 2026-03-06 时点，对当前主线 `rtl/` 的 **完整周期评估、500MHz 模块时序复核、赛题逐点合规分析、剩余风险与后续优化方向** 的正式整理。

本轮报告遵循上一个任务要求：

1. 以当前已经落地到 `rtl/` 的版本为准；
2. 对 `S=256, d=64, batch=1, head=1, causal` 的 baseline 做完整周期评估；
3. 对模块级 500MHz 进行重新复核；
4. 对尚未完成的项目，尤其是 top 级 STA/面积正式闭环，明确给出**估算与 caveat**，不做超范围结论；
5. 结合 `problem.md` 逐点给出当前状态。

---

## 目录

1. [01_项目摘要与阶段结论.md](01_项目摘要与阶段结论.md)
2. [02_当前RTL设计与数据流说明.md](02_当前RTL设计与数据流说明.md)
3. [03_验证结果与完整周期评估.md](03_验证结果与完整周期评估.md)
4. [04_500MHz_STA与面积风险分析.md](04_500MHz_STA与面积风险分析.md)
5. [05_赛题要求逐点符合性报告.md](05_赛题要求逐点符合性报告.md)
6. [06_当前问题清单与优化优先级.md](06_当前问题清单与优化优先级.md)
7. [07_面向Deep-Research-Agent的调研任务清单.md](07_面向Deep-Research-Agent的调研任务清单.md)
8. [08_复现命令与证据索引.md](08_复现命令与证据索引.md)

---

## 一页结论

- 当前主线 RTL 在修复归一化主路径后，一次 SDPA 的**主结论周期数**为 **148,656 cycles**；
- 相比题目要求的 **< 300k cycles**，当前周期指标**满足要求**，且仍有约 **2.02×** 余量；
- 本轮同时确认：此前 `145,584 cycles` 与 0305 一致，并不是评估流失真，而是因为当时主线 `fa_attention_core` 仍在使用**内联除法**，并未真正接入 `fa_recip_nr_q16_16`；
- 模块级 500MHz 复核后：
  - **满足**：`fa_recip_nr_q16_16`、`fa_axi_lite_regs`
  - **不满足**：`fa_mul_sat_q8_8`、`fa_exp_pwl_8seg_q1_15`
- `fa_online_softmax_update`、`fa_row_reduction_core`、`fa_core_controller`、`fa_tile_buffer`、`fa_dot_product_d`、`fa_clip_signed` 已确认不在主线 `fa_attention_ip_top -> fa_attention_core` 数据通路中，现已迁入 [useless/rtl_unused/README.md](useless/rtl_unused/README.md) 暂存；
- 当前最主要主线路径风险转为：`fa_mul_sat_q8_8` 与 `fa_exp_pwl_8seg_q1_15` 的 500MHz 收敛，以及 top 级正式 STA/面积闭环；
- 本轮没有继续对主线 RTL 做激进结构改写，原因不是缺少修改入口，而是：
  - 目前问题已不是简单重写几条组合逻辑即可闭合；
  - 若要继续冲击 500MHz，需要新的微架构方案证据支撑，否则高风险破坏当前正确性与周期结果；
- 顶层 `fa_attention_ip_top` 的**寄存器/启动/周期寄存器行为验证通过**，但 **top 级正式 STA 与正式面积闭环仍未完成**；
- 因此，本轮最准确口径是：
  - **功能与 baseline 周期目标：已基本满足**；
  - **模块级 500MHz：部分满足，计算核心未满足**；
  - **top 级 500MHz 与 2M 门面积约束：尚不能宣称达标**。