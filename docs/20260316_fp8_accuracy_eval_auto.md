# FP8 Accuracy Auto Report

- Seeds: 20260315..20260334 (20)
- Shape: S=64, D=32, TQ=32, TK=64

## Baseline
- score_scale_q1_14: 16384
- norm_round: False
- MAE avg/min/max: 3.198801105 / 2.987209647 / 3.356046887
- MaxAE avg: 8.000000000

## Candidate
- score_scale_q1_14: 8192
- norm_round: True
- MAE avg/min/max: 3.198022394 / 2.987071602 / 3.351148339
- MaxAE avg: 7.999511719

## Delta (Candidate vs Baseline)
- MAE improvement abs: 0.000778711
- MAE improvement pct: 0.024344%
