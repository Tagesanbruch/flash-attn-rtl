# WaveDrom 图清单与分类

本文用于区分 [docs/report_0310/大纲.md](../report_0310/%E5%A4%A7%E7%BA%B2.md) 中哪些图适合用 WaveDrom 离线生成，哪些图必须保留为真实仿真波形或工具截图。

| 图号 | 主题 | 建议形式 | 当前状态 | 备注 |
|---|---|---|---|---|
| 图10-1 | 当前 RTL 模块层级与 STA 覆盖关系 | 非 WaveDrom | 暂不生成 | 更适合 Mermaid/框图，强调层级与覆盖关系 |
| 图10-2 | 综合/STA 关键截图 | 真实截图 | 暂不生成 | 需要综合报告、STA 界面或关键日志截图 |
| 图10-3 | QK RTL pipeline | WaveDrom | 已生成源码/SVG | 当前改为仅保留主线 RTL 流水，不再展示实验迁移史 |
| 图10-4 | Norm RTL pipeline | WaveDrom | 已生成源码/SVG | 当前改为仅保留主线 RTL 流水，不再展示实验迁移史 |
| 图10-5 | 下一轮实验矩阵（QK / Norm） | 非 WaveDrom | 暂不生成 | 更适合表格或二维矩阵，不属于波形/时序图 |
| 图11-1 | 题目要求到 RTL 模块的映射 | 非 WaveDrom | 暂不生成 | 更适合需求-模块映射表或 Mermaid 图 |
| 图11-2 | 顶层结构图与 Q/K/V/O 数据流 | 非 WaveDrom | 暂不生成 | 更适合框图/数据流图，而非时序波形 |
| 图11-3 | Q tile / K-V tile 时序示意 | WaveDrom | 已生成源码/SVG | 英文缩写版，建议主放在第 3 节 |
| 图11-4 | online softmax 状态 `m/l/acc` 更新 | WaveDrom | 已生成源码/SVG | 使用 Unicode `α`/`β`，建议主放在第 3 节 |
| 图11-5 | DMA 读写握手与 tile buffer 装载 | WaveDrom | 已生成源码/SVG | 英文缩写版，建议主放在第 4 节 |
| 图11-6 | 顶层 perf counters 读回 | 真实截图 | 暂不生成 | 应保留寄存器读回日志或波形/终端截图 |

## 已生成 WaveDrom 源文件

- [fig10_3_qk_pipeline_migration.json](src/fig10_3_qk_pipeline_migration.json)
- [fig10_4_norm_datapath_split.json](src/fig10_4_norm_datapath_split.json)
- [fig11_3_tile_schedule.json](src/fig11_3_tile_schedule.json)
- [fig11_4_online_softmax_update.json](src/fig11_4_online_softmax_update.json)
- [fig11_5_dma_tilebuffer_handshake.json](src/fig11_5_dma_tilebuffer_handshake.json)

## 导出方式

- 安装依赖：已在本目录执行 `npm install`
- 导出命令：`node render.js`
- 输出目录：[docs/wavedrom/svg](svg)

## 当前正文放置建议

- 第 3 节：`fig11_3_tile_schedule`、`fig10_3_qk_pipeline_migration`、`fig11_4_online_softmax_update`、`fig10_4_norm_datapath_split`
- 第 4 节：`fig11_5_dma_tilebuffer_handshake`
- 第 10/11 节：保留真实截图、表格、总结性占位，不重复放解释性示意图
