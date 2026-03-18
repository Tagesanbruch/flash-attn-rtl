#!/usr/bin/env python3
"""Batch evaluate FP8-core approximation error against FP32 baseline.

This script runs deterministic random seeds, compares fixed-point FP8-core-like
attention output against an FP32 softmax baseline, and writes a markdown report.
"""

from __future__ import annotations

import argparse
import math
import random
from dataclasses import dataclass
from pathlib import Path


def s32(v: int) -> int:
    v &= 0xFFFFFFFF
    return v if v < 0x80000000 else v - 0x100000000


def fp8_e4m3_to_q4_11(x: int) -> int:
    sign = (x >> 7) & 1
    exp = (x >> 3) & 0xF
    frac = x & 0x7
    if exp == 0:
        mag = frac << 2
    elif exp == 0xF:
        mag = 32767
    else:
        mag = (8 + frac) << (exp + 1)
        mag = min(mag, 32767)
    return -mag if sign else mag


def exp2_shift_q0_15(delta_q8_11: int) -> int:
    d = delta_q8_11 >> 8
    if d >= 0:
        return 32767
    if d <= -15:
        return 0
    return 32767 >> (-d)


@dataclass
class EvalCfg:
    name: str
    score_scale_q1_14: int
    norm_round: bool


def run_one_seed(seed: int, s: int, d: int, tq: int, tk: int, cfg: EvalCfg) -> tuple[float, float]:
    rng = random.Random(seed)
    q = [[rng.randrange(0, 256) for _ in range(d)] for _ in range(s)]
    k = [[rng.randrange(0, 256) for _ in range(d)] for _ in range(s)]
    v = [[rng.randrange(0, 256) for _ in range(d)] for _ in range(s)]

    out = [[0 for _ in range(d)] for _ in range(s)]

    for qt in range(s // tq):
        row_m = [-(1 << 31) for _ in range(tq)]
        row_l = [0 for _ in range(tq)]
        row_acc = [[0 for _ in range(d)] for _ in range(tq)]

        for kt in range(s // tk):
            for qi in range(tq):
                gi = qt * tq + qi
                for kj in range(tk):
                    gj = kt * tk + kj
                    dot = 0
                    for dd in range(d):
                        dot += fp8_e4m3_to_q4_11(q[gi][dd]) * fp8_e4m3_to_q4_11(k[gj][dd])

                    score = dot >> 11
                    score = (score * cfg.score_scale_q1_14) >> 14
                    score = s32(max(-2147483648, min(2147483647, score)))

                    m_old = row_m[qi]
                    m_new = score if score > m_old else m_old

                    exp_old = 0 if row_l[qi] == 0 else exp2_shift_q0_15(m_old - m_new)
                    exp_new = exp2_shift_q0_15(score - m_new)

                    row_l[qi] = ((row_l[qi] * exp_old) >> 15) + (exp_new << 1)
                    for dd in range(d):
                        row_acc[qi][dd] = ((row_acc[qi][dd] * exp_old) >> 15) + fp8_e4m3_to_q4_11(v[gj][dd]) * exp_new

                    row_m[qi] = m_new

        for qi in range(tq):
            gi = qt * tq + qi
            den = row_l[qi]
            for dd in range(d):
                if den == 0:
                    out[gi][dd] = 0
                else:
                    num = row_acc[qi][dd]
                    if cfg.norm_round:
                        adj = den // 2
                        if num < 0:
                            adj = -adj
                        out[gi][dd] = s32(int((num + adj) / den))
                    else:
                        out[gi][dd] = s32(int(num / den))

    def decf(x: int) -> float:
        return fp8_e4m3_to_q4_11(x) / 2048.0

    qf = [[decf(x) for x in row] for row in q]
    kf = [[decf(x) for x in row] for row in k]
    vf = [[decf(x) for x in row] for row in v]

    errs = []
    for i in range(s):
        scores = [sum(qf[i][t] * kf[j][t] for t in range(d)) for j in range(s)]
        m = max(scores)
        ex = [math.exp(x - m) for x in scores]
        den = sum(ex)
        for t in range(d):
            ref = sum((ex[j] / den) * vf[j][t] for j in range(s))
            got = out[i][t] / 2048.0
            errs.append(abs(got - ref))

    mae = sum(errs) / len(errs)
    maxae = max(errs)
    return mae, maxae


def summarize(vals: list[tuple[float, float]]) -> tuple[float, float, float, float]:
    maes = [v[0] for v in vals]
    maxs = [v[1] for v in vals]
    return sum(maes) / len(maes), min(maes), max(maes), sum(maxs) / len(maxs)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--seed-start", type=int, default=20260315)
    p.add_argument("--seed-count", type=int, default=20)
    p.add_argument("--seq-len", type=int, default=64)
    p.add_argument("--head-dim", type=int, default=32)
    p.add_argument("--tq", type=int, default=32)
    p.add_argument("--tk", type=int, default=64)
    p.add_argument("--out", type=str, default="docs/20260316_fp8_accuracy_eval_auto.md")
    args = p.parse_args()

    cfgs = [
        EvalCfg(name="baseline", score_scale_q1_14=16384, norm_round=False),
        EvalCfg(name="candidate", score_scale_q1_14=8192, norm_round=True),
    ]

    seeds = [args.seed_start + i for i in range(args.seed_count)]
    all_res: dict[str, list[tuple[float, float]]] = {}

    for cfg in cfgs:
        vals = [run_one_seed(sd, args.seq_len, args.head_dim, args.tq, args.tk, cfg) for sd in seeds]
        all_res[cfg.name] = vals

    b_avg, b_min, b_max, b_maxae = summarize(all_res["baseline"])
    c_avg, c_min, c_max, c_maxae = summarize(all_res["candidate"])

    improve_abs = b_avg - c_avg
    improve_pct = (improve_abs / b_avg * 100.0) if b_avg != 0 else 0.0

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    lines = [
        "# FP8 Accuracy Auto Report",
        "",
        f"- Seeds: {args.seed_start}..{args.seed_start + args.seed_count - 1} ({args.seed_count})",
        f"- Shape: S={args.seq_len}, D={args.head_dim}, TQ={args.tq}, TK={args.tk}",
        "",
        "## Baseline",
        f"- score_scale_q1_14: 16384",
        f"- norm_round: False",
        f"- MAE avg/min/max: {b_avg:.9f} / {b_min:.9f} / {b_max:.9f}",
        f"- MaxAE avg: {b_maxae:.9f}",
        "",
        "## Candidate",
        f"- score_scale_q1_14: 8192",
        f"- norm_round: True",
        f"- MAE avg/min/max: {c_avg:.9f} / {c_min:.9f} / {c_max:.9f}",
        f"- MaxAE avg: {c_maxae:.9f}",
        "",
        "## Delta (Candidate vs Baseline)",
        f"- MAE improvement abs: {improve_abs:.9f}",
        f"- MAE improvement pct: {improve_pct:.6f}%",
    ]

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"[done] wrote {out_path}")


if __name__ == "__main__":
    main()
