# FP8 DMA Verif Latest

- max_err: 0
- mae: 0.000000
- maxae: 0
- mae_q: 0.000000
- maxae_q: 0.000000
- rtl_vs_cmodel_max: 0
- mae_fp32: 3.256571
- maxae_fp32: 8.000000

## Perf Registers
- rd_cmd: 72
- rd_beat: 17408
- wr_cmd: 8
- wr_beat: 4096
- compute_cycles: 32
- softmax_updates: 65536

## Expectations
- exp_rd_cmd: 72
- exp_rd_beat: 17408
- exp_wr_cmd: 8
- exp_wr_beat: 4096
- exp_comp: 32
- exp_soft: 65536

## Compliance Snapshot
- Functional alignment (RTL vs ref/cmodel): pass (`max_err=0`, `rtl_vs_cmodel_max=0`)
- FP8 vs FP32 AE gates from baseline problem statement (`MAE<=0.03`, `MaxAE<=0.10`): fail with current FP8 settings (`mae_fp32=3.256571`, `maxae_fp32=8.000000`)
