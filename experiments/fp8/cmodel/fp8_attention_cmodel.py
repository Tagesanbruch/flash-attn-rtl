#!/usr/bin/env python3
import argparse
import csv
import math
import random
from typing import List, Tuple


def percentile(vals: List[float], p: float) -> float:
    if not vals:
        return 0.0
    if len(vals) == 1:
        return vals[0]
    vals_sorted = sorted(vals)
    pos = (len(vals_sorted) - 1) * p
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return vals_sorted[lo]
    w = pos - lo
    return vals_sorted[lo] * (1.0 - w) + vals_sorted[hi] * w


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


def q4_11_to_float(x: int) -> float:
    return s32(x) / 2048.0


def round_shift(v: int, sh: int, mode: int) -> int:
    if sh <= 0:
        return v
    t = v
    if mode == 1:
        if v >= 0:
            t += 1 << (sh - 1)
        else:
            t -= 1 << (sh - 1)
    return t >> sh


def exp2_approx_q0_15(delta_q8_11: int) -> int:
    d = delta_q8_11 >> 8
    if d >= 0:
        return 32767
    if d <= -15:
        return 0
    return 32767 >> (-d)


def quant_q4_11(v: float) -> int:
    q = int(round(v * 2048.0))
    q = max(-2147483648, min(2147483647, q))
    return q


def metrics(got: List[List[float]], ref: List[List[float]]) -> Tuple[float, float, Tuple[int, int, float, float]]:
    n = 0
    abs_sum = 0.0
    maxe = 0.0
    worst = (0, 0, 0.0, 0.0)
    for i, (gr, rr) in enumerate(zip(got, ref)):
        for j, (g, r) in enumerate(zip(gr, rr)):
            e = abs(g - r)
            n += 1
            abs_sum += e
            if e > maxe:
                maxe = e
                worst = (i, j, g, r)
    mae = abs_sum / n if n else 0.0
    return mae, maxe, worst


def make_fp8_matrix(rng: random.Random, s: int, d: int) -> List[List[int]]:
    return [[rng.randrange(0, 256) for _ in range(d)] for _ in range(s)]


def fp32_reference(q: List[List[int]], k: List[List[int]], v: List[List[int]], scale_q1_14: int) -> List[List[float]]:
    s = len(q)
    d = len(q[0])
    scale = scale_q1_14 / float(1 << 14)

    qf = [[q4_11_to_float(fp8_e4m3_to_q4_11(x)) for x in row] for row in q]
    kf = [[q4_11_to_float(fp8_e4m3_to_q4_11(x)) for x in row] for row in k]
    vf = [[q4_11_to_float(fp8_e4m3_to_q4_11(x)) for x in row] for row in v]

    out = [[0.0 for _ in range(d)] for _ in range(s)]
    for i in range(s):
        scores = [0.0 for _ in range(s)]
        max_s = -1e30
        for j in range(s):
            dot = 0.0
            for dd in range(d):
                dot += qf[i][dd] * kf[j][dd]
            sc = dot * scale
            scores[j] = sc
            if sc > max_s:
                max_s = sc

        den = 0.0
        for j in range(s):
            scores[j] = math.exp(scores[j] - max_s)
            den += scores[j]

        for j in range(s):
            scores[j] /= den

        for dd in range(d):
            acc = 0.0
            for j in range(s):
                acc += scores[j] * vf[j][dd]
            out[i][dd] = acc
    return out


def rtl_strict_like(q: List[List[int]], k: List[List[int]], v: List[List[int]], scale_q1_14: int, round_mode: int = 0) -> List[List[float]]:
    s = len(q)
    d = len(q[0])
    qf = [[fp8_e4m3_to_q4_11(x) for x in row] for row in q]
    kf = [[fp8_e4m3_to_q4_11(x) for x in row] for row in k]
    vf = [[fp8_e4m3_to_q4_11(x) for x in row] for row in v]

    out_i32 = [[0 for _ in range(d)] for _ in range(s)]
    for i in range(s):
        score = [0 for _ in range(s)]
        row_max = -(1 << 31)
        for j in range(s):
            dot = 0
            for dd in range(d):
                dot += qf[i][dd] * kf[j][dd]
            sc = round_shift(dot, 11, round_mode)
            sc = (sc * scale_q1_14) >> 14
            sc = s32(sc)
            score[j] = sc
            row_max = max(row_max, sc)

        den = 0
        num = [0 for _ in range(d)]
        for j in range(s):
            e = exp2_approx_q0_15(score[j] - row_max)
            den += e
            for dd in range(d):
                num[dd] += vf[j][dd] * e

        if den != 0:
            for dd in range(d):
                out_i32[i][dd] = s32(int(num[dd] / den))

    return [[q4_11_to_float(x) for x in row] for row in out_i32]


def proposed_online_floatexp(q: List[List[int]], k: List[List[int]], v: List[List[int]], scale_q1_14: int) -> List[List[float]]:
    s = len(q)
    d = len(q[0])
    qf = [[q4_11_to_float(fp8_e4m3_to_q4_11(x)) for x in row] for row in q]
    kf = [[q4_11_to_float(fp8_e4m3_to_q4_11(x)) for x in row] for row in k]
    vf = [[q4_11_to_float(fp8_e4m3_to_q4_11(x)) for x in row] for row in v]
    scale = scale_q1_14 / float(1 << 14)

    out = [[0.0 for _ in range(d)] for _ in range(s)]
    for i in range(s):
        m = -1e30
        l = 0.0
        acc = [0.0 for _ in range(d)]
        for j in range(s):
            dot = 0.0
            for dd in range(d):
                dot += qf[i][dd] * kf[j][dd]
            sc = dot * scale

            m_new = max(m, sc)
            exp_old = 0.0 if m <= -1e20 else math.exp(m - m_new)
            exp_new = math.exp(sc - m_new)
            l = l * exp_old + exp_new

            for dd in range(d):
                acc[dd] = acc[dd] * exp_old + vf[j][dd] * exp_new
            m = m_new

        inv = 1.0 / l if l > 0 else 0.0
        for dd in range(d):
            out[i][dd] = q4_11_to_float(quant_q4_11(acc[dd] * inv))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--s", type=int, default=256)
    ap.add_argument("--d", type=int, default=64)
    ap.add_argument("--seed", type=int, default=20260315)
    ap.add_argument("--n-seeds", type=int, default=3)
    ap.add_argument("--scale-q1-14", type=int, default=1 << 14)
    ap.add_argument("--csv-out", type=str, default="out/fp8_cmodel_report.csv")
    args = ap.parse_args()

    rows = []
    mae_by_mode = {"rtl_strict_like": [], "proposed_online_floatexp": []}
    max_by_mode = {"rtl_strict_like": [], "proposed_online_floatexp": []}
    for t in range(args.n_seeds):
        seed = args.seed + t
        rng = random.Random(seed)
        q = make_fp8_matrix(rng, args.s, args.d)
        k = make_fp8_matrix(rng, args.s, args.d)
        v = make_fp8_matrix(rng, args.s, args.d)

        ref = fp32_reference(q, k, v, args.scale_q1_14)
        rtl = rtl_strict_like(q, k, v, args.scale_q1_14)
        prop = proposed_online_floatexp(q, k, v, args.scale_q1_14)

        mae_rtl, max_rtl, worst_rtl = metrics(rtl, ref)
        mae_prop, max_prop, worst_prop = metrics(prop, ref)

        mae_by_mode["rtl_strict_like"].append(mae_rtl)
        mae_by_mode["proposed_online_floatexp"].append(mae_prop)
        max_by_mode["rtl_strict_like"].append(max_rtl)
        max_by_mode["proposed_online_floatexp"].append(max_prop)

        rows.append([
            seed,
            "rtl_strict_like",
            f"{mae_rtl:.6f}",
            f"{max_rtl:.6f}",
            worst_rtl,
        ])
        rows.append([
            seed,
            "proposed_online_floatexp",
            f"{mae_prop:.6f}",
            f"{max_prop:.6f}",
            worst_prop,
        ])

        print(
            f"[fp8-cmodel] seed={seed} rtl_strict_like mae={mae_rtl:.6f} max={max_rtl:.6f} | "
            f"proposed_online_floatexp mae={mae_prop:.6f} max={max_prop:.6f}"
        )

    with open(args.csv_out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["seed", "mode", "mae", "max_err", "worst"])
        w.writerows(rows)

    for mode in ("rtl_strict_like", "proposed_online_floatexp"):
        mae_vals = mae_by_mode[mode]
        max_vals = max_by_mode[mode]
        print(
            f"[fp8-cmodel] summary mode={mode} "
            f"mae_p50={percentile(mae_vals, 0.50):.6f} "
            f"mae_p90={percentile(mae_vals, 0.90):.6f} "
            f"mae_p99={percentile(mae_vals, 0.99):.6f} "
            f"max_p50={percentile(max_vals, 0.50):.6f} "
            f"max_p90={percentile(max_vals, 0.90):.6f} "
            f"max_p99={percentile(max_vals, 0.99):.6f}"
        )

    print(f"[fp8-cmodel] csv written: {args.csv_out}")


if __name__ == "__main__":
    main()
