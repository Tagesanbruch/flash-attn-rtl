# 0310 报告工件索引

## 1. 收集命令
- [logs/collect_artifacts.log](logs/collect_artifacts.log)
- [logs/syn_coverage_audit.txt](logs/syn_coverage_audit.txt)
- [logs/sta_exp_g_frontend.log](logs/sta_exp_g_frontend.log)

## 2. 最佳综合/STA 工件
- `fa_recip_nr_q16_16` 最佳： [syn/best_recip_exp_c](syn/best_recip_exp_c)
- `fa_online_softmax_ctx` 最佳： [syn/best_softmax_exp_d](syn/best_softmax_exp_d)
- `fa_o_normalize_block_pipe` 最佳： [syn/best_norm_exp_d](syn/best_norm_exp_d)
- `fa_qk_dotprod_slice_pipe` 最佳： [syn/best_qk_exp_h](syn/best_qk_exp_h)

## 3. native 推理相关工件
- [logs/native/perf.log](logs/native/perf.log)
- [logs/native/trace.log](logs/native/trace.log)
- [logs/native/q8_8_perf_results.csv](logs/native/q8_8_perf_results.csv)
- [logs/native/q8_8_text_results.csv](logs/native/q8_8_text_results.csv)
- [logs/native/q8_8_evaluation_results.csv](logs/native/q8_8_evaluation_results.csv)
- [logs/native/err.txt](logs/native/err.txt)
- [logs/native/Makefile.snapshot](logs/native/Makefile.snapshot)

## 4. 说明
本目录优先保存“当前每个关键模块的最佳现状”对应工件，而不是重复保存全部历史实验副本。QK 点积仅保留 `exp_h`，softmax 仅保留 `exp_d`，normalize 仅保留 `exp_d`，倒数仅保留 `exp_c`。
