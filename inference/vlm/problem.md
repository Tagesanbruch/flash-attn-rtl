
# IEEE AICAS 2026 Grand Challenge – 端侧VLM推理FPGA软硬件系统设计赛道

## 测试评分标准

| 评价指标 | 评价内容 | 使用方法 |
| :--- | :--- | :--- |
| **模型推理精度（Ability）** | 精度能力测试 | 本地运行分析工具，生成json文件 |
| **模型推理性能（Efficiency）** | 吞吐量提升率 | 本地运行分析工具，生成json文件 |

---

### A. 初赛评价指标

#### 1.模型推理精度评估

**准确率测试：** 在该赛道中，使用测试集OCRBench进行 $n$ 个测试样例的精度测试，每个OCRBench的测试样例提供一张图片，一个问题和一个答案，模型需要根据输入的图片和问题对正确的答案进行输出，其中设定正确答案的字符串为 $\{p_i\}, i \in[1, n]$。选手在KV260平台上部署的SmolVLM2-500M-Video-Instruct对于给定输入下的输出为 $\{q_i\}, i \in [1, n]$，程序中以 $p_i \subseteq q_i$ 作为正确的指标，我们使用下列式子作为准确率：

$$Ratio_{accuracy} = (\sum_{i=1}^{n} 1_{p_i \subseteq q_i}) / n$$

在初赛中，$n$ 的值被设定为100。

#### 2.模型推理性能评估

**prefill和decoding吞吐量提升率：** 以初始SmolVLM2-500M-Video-Instruct在硬件平台的吞吐量作为 $T_{ori}$，以优化后的SmolVLM2-500M-Video-Instruct吞吐量作为 $T_{opt}$，prefill和decoding两阶段结果分别计算。具体计算公式如下：

Prefill阶段：

$$Ratio_{throughput\_P} = \frac{T_{opt\_P} - T_{ori\_P}}{T_{opt\_P}} = 1 - \frac{T_{ori\_P}}{T_{opt\_P}}$$

Decoding阶段：

$$Ratio_{throughput\_D} = \frac{T_{opt\_D} - T_{ori\_D}}{T_{opt\_D}} = 1 - \frac{T_{ori\_D}}{T_{opt\_D}}$$

我们鼓励参赛选手进行硬件层面的优化，以达到更高的模型吞吐量为目标。

#### 3.初赛总分计算方法

在比赛开始前，主办方通过完全随机的方式从OCRBench的所有数据集中选择100个数据，并将其保存为json格式，选手在比赛结束前无法获取到该json文件的内容，主办方将提供完全随机的采样代码提供给每个队伍进行测试，同时公布在没有任何优化的情况下的准确率数据。

在比赛结束后，主办方将公布准备好的json测试文件，并对选手提交的优化后的FPGA加速工程进行准确率评估，**我们会对所有的队伍使用相同的测试文件**。并与原始权重状态下的准确率进行比较，分别记为 $Acc_{ori}, Acc_{opt}$，对于精度测试，其测试通过以下公式进行：

$$Acc_{opt} \ge Acc_{ori} - 5\%$$

在通过精度测试后，将进行模型推理性能评估，得到初赛的总分。

初赛的总分将被加权计算，各项指标在加权公式中会以全部参赛团队中每项的最高分进行归一化。选手们将自己的结果上传至天池平台，平台会线上给出总分结果和排名。具体计算公式如下：

$$Score = 50 \times \frac{Ratio_{throughput\_P}}{MAX(Ratio_{throughput\_P})} + 50 \times \frac{Ratio_{throughput\_D}}{MAX(Ratio_{throughput\_D})}$$

**由于天池排行榜的测评限制，在线排行榜显示的分数为：**

$$Score = 50 \times Ratio_{throughput\_P} + 50 \times Ratio_{throughput\_D}$$

#### 现阶段参赛作品的要求包括：

*   **测试报告：** 介绍本队伍对SmolVLM2-500M-Video-Instruct进行优化后的测试结果，并提供指定第三方测试软件运行结果文档。
*   **技术文档：** 介绍本队伍对大模型实现优化方法，我们将提供一个markdown模板作为参考。
*   **实现优化方法的源代码。**

---

### B.复赛评价指标

复赛的评价标准将基于初赛的结果进行适当的调整。

#### 在最后一轮比赛结束后，参赛队伍需要提交：

*   **参赛论文：** 以论文形式介绍本队伍VLM应用场景，软硬件协同设计方案，以及优化前后各评价指标的对比效果和性能总结。
*   **源代码：** 必须提交用于优化模型的实际源代码。（竞赛组织方有权利在开源社区（例如Github, Huggingface等）中使用GC参赛团队的代码和开发案例作为宣传材料，或者用于其在赞助商相关产品的开源工具中）

---

### 相关链接

*   2026 AICAS: https://2026.ieee-aicas.org/
*   T-Head Semiconductor Co., Ltd.: https://www.t-head.cn/
*   SmolVLM2: https://huggingface.co/blog/smolvlm2
*   Huggingface (Global download link for SmolVLM2 model): https://huggingface.co/HuggingFaceTB/SmolVLM2-500M-Video-Instruct
*   Modelscope (Chinese download link for SmolVLM2 model): https://modelscope.cn/models/HuggingFaceTB/SmolVLM2-500M-Video-Instruct
*   KV260: https://www.amd.com/en/products/system-on-modules/kria/k26/kv260-vision-starter-kit.html#specifications
*   Llama.cpp: https://github.com/ggml-org/llama.cpp