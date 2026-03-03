#!/usr/bin/env python3
import argparse
import csv
import math
from pathlib import Path

import numpy as np

from ref_attention import online_row_attention_q8_8, quant_q8_8, dequant_q8_8


def direct_softmax_attention(q: np.ndarray, k: np.ndarray, v: np.ndarray, causal: bool) -> np.ndarray:
    s, d = q.shape
    scale = 1.0 / math.sqrt(float(d))
    out = np.zeros((s, d), dtype=np.float32)
    for i in range(s):
        score = (k @ q[i]).astype(np.float32) * scale
        if causal:
            score[i + 1 :] = -1e9
        m = np.max(score)
        p = np.exp(score - m)
        p = p / np.sum(p)
        out[i] = p @ v
    return out


def online_softmax_exact(q: np.ndarray, k: np.ndarray, v: np.ndarray, causal: bool) -> np.ndarray:
    s, d = q.shape
    scale = 1.0 / math.sqrt(float(d))
    out = np.zeros((s, d), dtype=np.float32)
    for i in range(s):
        m = -1e30
        l = 0.0
        acc = np.zeros((d,), dtype=np.float32)
        for j in range(s):
            score = float(np.dot(q[i], k[j]) * scale)
            if causal and j > i:
                score = -1e9
            m_new = max(m, score)
            alpha = math.exp(m - m_new) if m > -1e20 else 0.0
            p = math.exp(score - m_new)
            l = alpha * l + p
            acc = alpha * acc + p * v[j]
            m = m_new
        out[i] = acc / l
    return out


def metrics(a: np.ndarray, b: np.ndarray) -> dict:
    diff = a - b
    abs_e = np.abs(diff)
    return {
        "mae": float(np.mean(abs_e)),
        "maxe": float(np.max(abs_e)),
        "rmse": float(np.sqrt(np.mean(diff * diff))),
        "p99": float(np.percentile(abs_e, 99)),
    }


def run_case(s: int, d: int, seed: int, causal: bool) -> dict:
    np.random.seed(seed)
    q = np.random.randn(s, d).astype(np.float32)
    k = np.random.randn(s, d).astype(np.float32)
    v = np.random.randn(s, d).astype(np.float32)

    q_q = dequant_q8_8(quant_q8_8(q))
    k_q = dequant_q8_8(quant_q8_8(k))
    v_q = dequant_q8_8(quant_q8_8(v))

    direct = direct_softmax_attention(q_q, k_q, v_q, causal=causal)
    online_exact = online_softmax_exact(q_q, k_q, v_q, causal=causal)
    rtl_like = online_row_attention_q8_8(q, k, v, causal=causal)

    m_online = metrics(online_exact, direct)
    m_rtl = metrics(rtl_like, direct)

    row0_mask_violation = float(np.max(np.abs(direct[0] - v_q[0]))) if causal else 0.0

    return {
        "s": s,
        "d": d,
        "seed": seed,
        "causal": int(causal),
        "online_vs_direct_mae": m_online["mae"],
        "online_vs_direct_maxe": m_online["maxe"],
        "rtl_vs_direct_mae": m_rtl["mae"],
        "rtl_vs_direct_maxe": m_rtl["maxe"],
        "rtl_vs_direct_rmse": m_rtl["rmse"],
        "rtl_vs_direct_p99": m_rtl["p99"],
        "causal_row0_deviation": row0_mask_violation,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=str, default="report/data/20260303_algorithm_audit.csv")
    parser.add_argument("--seeds", type=int, default=5)
    args = parser.parse_args()

    cases = [
        (64, 64, True),
        (64, 64, False),
        (128, 64, True),
        (256, 64, True),
    ]

    rows = []
    base_seed = 20260303
    for (s, d, causal) in cases:
        for k in range(args.seeds):
            rows.append(run_case(s=s, d=d, seed=base_seed + k, causal=causal))

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    keys = list(rows[0].keys())
    with out_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=keys)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} rows to {out_path}")

    def summary(filter_fn, key):
        vals = [r[key] for r in rows if filter_fn(r)]
        return float(np.mean(vals)), float(np.max(vals))

    mean_mae, max_mae = summary(lambda r: r["causal"] == 1 and r["s"] == 256, "rtl_vs_direct_mae")
    mean_maxe, max_maxe = summary(lambda r: r["causal"] == 1 and r["s"] == 256, "rtl_vs_direct_maxe")
    mean_strict, max_strict = summary(lambda r: True, "online_vs_direct_maxe")

    print(
        "S=256,d=64,causal RTL-like vs direct: "
        f"MAE(mean/max)={mean_mae:.6f}/{max_mae:.6f}, "
        f"MaxAE(mean/max)={mean_maxe:.6f}/{max_maxe:.6f}"
    )
    print(
        "Online exact vs direct equivalence: "
        f"MaxAE(mean/max)={mean_strict:.6e}/{max_strict:.6e}"
    )


if __name__ == "__main__":
    main()
