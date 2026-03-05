#!/usr/bin/env python3
import csv
from pathlib import Path
from statistics import mean

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "docs" / "data"

SOL_FILES = [
    DATA / "20260304_solution_compare_smallint_causal_neg.csv",
    DATA / "20260304_solution_compare_smallint_causal_hard.csv",
    DATA / "20260304_solution_compare_gaussian_causal_neg.csv",
    DATA / "20260304_solution_compare_gaussian_causal_hard.csv",
]

MODES = [
    "rtl_exact",
    "rtl_real_exp",
    "rtl_real_exp_float_norm",
    "fixed_hiacc_qout",
    "fixed_hiacc_real_exp_qout",
    "fp32_then_q8",
]


def read_csv(path: Path):
    with path.open("r", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def summarize_solution_compare():
    rows = []
    for path in SOL_FILES:
        records = read_csv(path)
        grouped = {m: [] for m in MODES}
        for r in records:
            m = r["mode"]
            if m in grouped:
                grouped[m].append(r)

        for m in MODES:
            g = grouped[m]
            if not g:
                continue
            maes = [float(x["mae"]) for x in g]
            maxes = [float(x["maxe"]) for x in g]
            rmses = [float(x["rmse"]) for x in g]
            rows.append(
                {
                    "source_csv": path.name,
                    "mode": m,
                    "mae_mean": f"{mean(maes):.9f}",
                    "maxae_worst": f"{max(maxes):.9f}",
                    "rmse_mean": f"{mean(rmses):.9f}",
                    "mae_pass_0p03": "PASS" if mean(maes) <= 0.03 else "FAIL",
                    "maxae_pass_0p10": "PASS" if max(maxes) <= 0.10 else "FAIL",
                }
            )

    out = DATA / "20260305_p1_approx_scan_summary.csv"
    with out.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "source_csv",
                "mode",
                "mae_mean",
                "maxae_worst",
                "rmse_mean",
                "mae_pass_0p03",
                "maxae_pass_0p10",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)
    return out


def summarize_bandwidth():
    summary = read_csv(DATA / "20260304_rtl_summary.csv")
    s = {r["metric"]: float(r["value"]) for r in summary}

    beats_rd_q = s.get("rd_q_cycles", 0.0)
    beats_rd_k = s.get("rd_k_cycles", 0.0)
    beats_rd_v = s.get("rd_v_cycles", 0.0)
    beats_wr_o = s.get("wr_o_cycles", 0.0)
    total_cycles = s.get("total_cycles", 1.0)

    beat_bytes = 16.0
    rd_bytes = (beats_rd_q + beats_rd_k + beats_rd_v) * beat_bytes
    wr_bytes = beats_wr_o * beat_bytes
    total_bytes = rd_bytes + wr_bytes
    bw_bytes_per_cycle = total_bytes / total_cycles
    bus_peak_bytes_per_cycle = beat_bytes
    bus_util = bw_bytes_per_cycle / bus_peak_bytes_per_cycle

    out = DATA / "20260305_p1_bandwidth_summary.csv"
    with out.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["metric", "value"],
        )
        writer.writeheader()
        writer.writerows(
            [
                {"metric": "total_cycles", "value": f"{total_cycles:.0f}"},
                {"metric": "rd_bytes", "value": f"{rd_bytes:.0f}"},
                {"metric": "wr_bytes", "value": f"{wr_bytes:.0f}"},
                {"metric": "total_bytes", "value": f"{total_bytes:.0f}"},
                {"metric": "avg_bytes_per_cycle", "value": f"{bw_bytes_per_cycle:.6f}"},
                {"metric": "bus_peak_bytes_per_cycle", "value": f"{bus_peak_bytes_per_cycle:.6f}"},
                {"metric": "bus_utilization", "value": f"{bus_util:.6f}"},
            ]
        )
    return out


def main():
    approx = summarize_solution_compare()
    bw = summarize_bandwidth()
    print(f"[p1] wrote {approx}")
    print(f"[p1] wrote {bw}")


if __name__ == "__main__":
    main()
