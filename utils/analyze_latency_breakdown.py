#!/usr/bin/env python3
import argparse
import csv
from pathlib import Path


def read_summary(path: Path):
    out = {}
    with path.open() as f:
        r = csv.DictReader(f)
        for row in r:
            k = row["metric"]
            v = float(row["value"])
            out[k] = v
    return out


def read_timeline(path: Path):
    events = []
    with path.open() as f:
        r = csv.DictReader(f)
        for row in r:
            events.append({
                "cycle": int(row["cycle"]),
                "event": row["event"],
                "kind": row["kind"],
                "addr": int(row["addr"]),
                "beats": int(row["beats"]),
            })
    return events


def infer_phase_cycles(events, total_cycles):
    # Heuristic phase extraction from command timeline.
    # Measure gaps after V-load completion as compute+normalize candidate.
    gap_compute_norm = 0
    last_cycle = 0
    last_evt = None
    for e in events:
        c = e["cycle"]
        if last_evt is not None and c >= last_cycle:
            if last_evt["event"] == "rd_done" and last_evt["kind"] == "V" and e["event"] in {"rd_cmd", "wr_cmd", "done"}:
                gap_compute_norm += (c - last_cycle)
        last_cycle = c
        last_evt = e

    return {"compute_norm_gap": gap_compute_norm, "total_cycles": total_cycles}


def write_breakdown_csv(path: Path, rows):
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["category", "cycles", "percent"])
        total = sum(v for _, v in rows)
        for k, v in rows:
            pct = (100.0 * v / total) if total > 0 else 0.0
            w.writerow([k, int(v), f"{pct:.4f}"])


def read_cmodel_cycle_csv(path: Path):
    rows = []
    with path.open() as f:
        r = csv.DictReader(f)
        for row in r:
            rows.append(row)
    return rows


def choose_cmodel_model(rows, model_name):
    if not rows:
        return None
    if model_name:
        for row in rows:
            if row.get("model", "") == model_name:
                return row
    for row in rows:
        if int(row.get("target_300k_pass", "0")) == 1:
            return row
    return min(rows, key=lambda r: int(r.get("total_compute_only_cycles", "0")))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", required=True)
    ap.add_argument("--timeline", required=True)
    ap.add_argument("--out-csv", required=True)
    ap.add_argument("--out-compute-csv", default="")
    ap.add_argument("--cmodel-cycle-csv", default="")
    ap.add_argument("--cmodel-model", default="")
    ap.add_argument("--out-rtl-cmodel-csv", default="")
    args = ap.parse_args()

    s = read_summary(Path(args.summary))
    ev = read_timeline(Path(args.timeline))
    inf = infer_phase_cycles(ev, int(s["total_cycles"]))

    rows = [
        ("DMA_RD_Q", int(s.get("rd_q_cycles", 0))),
        ("DMA_RD_K", int(s.get("rd_k_cycles", 0))),
        ("DMA_RD_V", int(s.get("rd_v_cycles", 0))),
        ("DMA_WR_O", int(s.get("wr_o_cycles", 0))),
        ("Compute+Normalize+Ctrl", int(s.get("non_dma_cycles", 0))),
        ("GapAfterV_toNextCmd(heuristic)", int(inf["compute_norm_gap"])),
    ]

    write_breakdown_csv(Path(args.out_csv), rows)

    if args.out_compute_csv:
        fine_rows = [
            ("Compute:DP", int(s.get("cs_dp_cycles", 0))),
            ("Compute:Score", int(s.get("cs_score_cycles", 0))),
            ("Compute:Softmax+PV", int(s.get("cs_softmax_pv_cycles", 0))),
            ("Compute:Ctrl", int(s.get("cs_ctrl_cycles", 0))),
            ("Normalize", int(s.get("ms_normalize_cycles", 0))),
        ]
        write_breakdown_csv(Path(args.out_compute_csv), fine_rows)

    if args.cmodel_cycle_csv and args.out_rtl_cmodel_csv:
        c_rows = read_cmodel_cycle_csv(Path(args.cmodel_cycle_csv))
        c_sel = choose_cmodel_model(c_rows, args.cmodel_model)
        if c_sel is not None:
            rtl_compute = int(s.get("ms_compute_cycles", 0))
            rtl_norm = int(s.get("ms_normalize_cycles", 0))
            rtl_total = rtl_compute + rtl_norm

            c_compute = int(float(c_sel.get("compute_cycles", "0")))
            c_norm = int(float(c_sel.get("norm_cycles", "0")))
            c_noc = int(float(c_sel.get("noc_cycles", "0")))
            c_total = int(float(c_sel.get("total_compute_only_cycles", "0")))

            with Path(args.out_rtl_cmodel_csv).open("w", newline="") as f:
                w = csv.writer(f)
                w.writerow(["category", "rtl_cycles", "cmodel_cycles", "delta_rtl_minus_cmodel", "cmodel_model"])
                w.writerow(["ComputeOnly", rtl_compute, c_compute, rtl_compute - c_compute, c_sel.get("model", "")])
                w.writerow(["Normalize", rtl_norm, c_norm, rtl_norm - c_norm, c_sel.get("model", "")])
                w.writerow(["NoC_Overhead", 0, c_noc, -c_noc, c_sel.get("model", "")])
                w.writerow(["Compute+Norm_Total", rtl_total, c_total, rtl_total - c_total, c_sel.get("model", "")])

    print("[latency] breakdown written:", args.out_csv)
    if args.out_compute_csv:
        print("[latency] fine compute breakdown written:", args.out_compute_csv)
    if args.cmodel_cycle_csv and args.out_rtl_cmodel_csv:
        print("[latency] rtl-cmodel compare written:", args.out_rtl_cmodel_csv)
    print("[latency] total_cycles=", int(s.get("total_cycles", 0)))
    print("[latency] rtl_fp32_mae=", s.get("rtl_fp32_mae", 0.0), "maxae=", s.get("rtl_fp32_maxae", 0.0))


if __name__ == "__main__":
    main()
