#!/usr/bin/env python3
import argparse
import csv
import numpy as np

from ref_attention import online_row_attention_q8_8


def calc_metrics(ref: np.ndarray, torch_out: np.ndarray):
    abs_err = np.abs(ref - torch_out)
    mae = float(np.mean(abs_err))
    maxe = float(np.max(abs_err))
    rmse = float(np.sqrt(np.mean((ref - torch_out) ** 2)))
    p95 = float(np.percentile(abs_err, 95))
    p99 = float(np.percentile(abs_err, 99))
    mean_ref_abs = float(np.mean(np.abs(torch_out)))
    rel_mae = float(mae / (mean_ref_abs + 1e-12))
    return {
        "mae": mae,
        "maxe": maxe,
        "rmse": rmse,
        "p95": p95,
        "p99": p99,
        "rel_mae": rel_mae,
    }


def vec_preview(arr: np.ndarray, row: int = 0, n: int = 8) -> str:
    clipped = arr[row, :n]
    return np.array2string(clipped, precision=5, suppress_small=False)


def zero_ratio(arr: np.ndarray, eps: float = 1e-12) -> float:
    return float(np.mean(np.abs(arr) <= eps))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--s", type=int, default=64)
    parser.add_argument("--d", type=int, default=64)
    parser.add_argument("--seed", type=int, default=20260302)
    parser.add_argument("--n-seeds", type=int, default=1)
    parser.add_argument("--causal", action="store_true")
    parser.add_argument("--mae-thres", type=float, default=0.03)
    parser.add_argument("--maxe-thres", type=float, default=0.10)
    parser.add_argument("--csv-out", type=str, default="")
    args = parser.parse_args()

    try:
        import torch
        import torch.nn.functional as F
    except Exception:
        print("[SKIP] torch is not installed. Install torch to run compare.")
        return

    all_metrics = []
    csv_rows = []

    print(f"S={args.s}, d={args.d}, causal={args.causal}, n_seeds={args.n_seeds}")
    for idx in range(args.n_seeds):
        seed = args.seed + idx
        np.random.seed(seed)
        q = np.random.randn(args.s, args.d).astype(np.float32)
        k = np.random.randn(args.s, args.d).astype(np.float32)
        v = np.random.randn(args.s, args.d).astype(np.float32)

        ref = online_row_attention_q8_8(q, k, v, causal=args.causal)

        tq = torch.tensor(q, dtype=torch.float32).unsqueeze(0).unsqueeze(0)
        tk = torch.tensor(k, dtype=torch.float32).unsqueeze(0).unsqueeze(0)
        tv = torch.tensor(v, dtype=torch.float32).unsqueeze(0).unsqueeze(0)

        if args.causal:
            out = F.scaled_dot_product_attention(tq, tk, tv, is_causal=True)
        else:
            out = F.scaled_dot_product_attention(tq, tk, tv, is_causal=False)

        torch_out = out.squeeze(0).squeeze(0).detach().cpu().numpy()
        metrics = calc_metrics(ref, torch_out)
        all_metrics.append(metrics)

        ref_zero = zero_ratio(ref)
        torch_zero = zero_ratio(torch_out)
        diff_zero = zero_ratio(ref - torch_out)
        ref_mean_abs = float(np.mean(np.abs(ref)))
        torch_mean_abs = float(np.mean(np.abs(torch_out)))
        ref_std = float(np.std(ref))
        torch_std = float(np.std(torch_out))

        print(
            f"seed={seed} "
            f"MAE={metrics['mae']:.6f} "
            f"MaxAE={metrics['maxe']:.6f} "
            f"RMSE={metrics['rmse']:.6f} "
            f"P95={metrics['p95']:.6f} "
            f"P99={metrics['p99']:.6f} "
            f"RelMAE={metrics['rel_mae']:.6f}"
        )
        print(
            f"  ref_mean_abs={ref_mean_abs:.6f}, torch_mean_abs={torch_mean_abs:.6f}, "
            f"ref_std={ref_std:.6f}, torch_std={torch_std:.6f}"
        )
        print(
            f"  zero_ratio(ref/torch/diff)={ref_zero:.6f}/{torch_zero:.6f}/{diff_zero:.6f}"
        )
        print(f"  ref_row0[:8]   = {vec_preview(ref, row=0, n=8)}")
        print(f"  torch_row0[:8] = {vec_preview(torch_out, row=0, n=8)}")

        csv_rows.append(
            {
                "seed": seed,
                "s": args.s,
                "d": args.d,
                "causal": int(args.causal),
                "mae": metrics["mae"],
                "maxe": metrics["maxe"],
                "rmse": metrics["rmse"],
                "p95": metrics["p95"],
                "p99": metrics["p99"],
                "rel_mae": metrics["rel_mae"],
                "ref_mean_abs": ref_mean_abs,
                "torch_mean_abs": torch_mean_abs,
                "ref_std": ref_std,
                "torch_std": torch_std,
                "ref_zero_ratio": ref_zero,
                "torch_zero_ratio": torch_zero,
                "diff_zero_ratio": diff_zero,
            }
        )

    mae_list = np.array([m["mae"] for m in all_metrics], dtype=np.float64)
    maxe_list = np.array([m["maxe"] for m in all_metrics], dtype=np.float64)
    rmse_list = np.array([m["rmse"] for m in all_metrics], dtype=np.float64)

    print("-" * 72)
    print(
        f"Summary: MAE(mean/max)={mae_list.mean():.6f}/{mae_list.max():.6f}, "
        f"MaxAE(mean/max)={maxe_list.mean():.6f}/{maxe_list.max():.6f}, "
        f"RMSE(mean/max)={rmse_list.mean():.6f}/{rmse_list.max():.6f}"
    )

    pass_mae = float(mae_list.max()) <= args.mae_thres
    pass_maxe = float(maxe_list.max()) <= args.maxe_thres
    print(
        f"Threshold check (worst over seeds): "
        f"MAE<={args.mae_thres} -> {pass_mae}, "
        f"MaxAE<={args.maxe_thres} -> {pass_maxe}"
    )

    if args.csv_out:
        with open(args.csv_out, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(csv_rows[0].keys()))
            writer.writeheader()
            writer.writerows(csv_rows)
        print(f"CSV written: {args.csv_out}")


if __name__ == "__main__":
    main()
