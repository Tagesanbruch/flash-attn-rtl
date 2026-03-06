#!/usr/bin/env python3
import os
import re

BASE = "syn"
DATE = "20260304"
MODULES = [
    "fa_mul_sat_q8_8",
    "fa_exp_pwl_8seg_q1_15",
    "fa_recip_nr_q16_16",
    "fa_axi_lite_regs",
]


def parse_module(module: str):
    report_dir = f"{BASE}/{module}_{DATE}/{module}-500MHz"
    stat_path = os.path.join(report_dir, "synth_stat.txt")
    rpt_path = os.path.join(report_dir, f"{module}.rpt")
    sta_log_path = os.path.join(report_dir, "sta.log")

    area = None
    inst = None
    max_slack = None
    min_slack = None
    tns_max = None
    tns_min = None
    status = "missing"

    if os.path.exists(stat_path):
        txt = open(stat_path, "r", encoding="utf-8", errors="ignore").read()
        ma = re.search(r"Chip area for module '\\?[^']+':\s*([0-9.]+)", txt)
        if ma:
            area = float(ma.group(1))
        mi = re.search(r"\n\s*(\d+)\s+[0-9.]+\s+cells", txt)
        if mi:
            inst = int(mi.group(1))

    if os.path.exists(rpt_path):
        for line in open(rpt_path, "r", encoding="utf-8", errors="ignore"):
            if not line.startswith("|"):
                continue
            parts = [p.strip() for p in line.strip("|\n").split("|")]
            if len(parts) >= 8 and parts[2] in ("max", "min"):
                try:
                    slack = float(parts[6])
                except ValueError:
                    continue
                if parts[2] == "max":
                    max_slack = slack if max_slack is None else min(max_slack, slack)
                else:
                    min_slack = slack if min_slack is None else min(min_slack, slack)
            elif len(parts) == 3 and parts[0] == "core_clock":
                try:
                    if parts[1] == "max":
                        tns_max = float(parts[2])
                    elif parts[1] == "min":
                        tns_min = float(parts[2])
                except ValueError:
                    pass
        status = "ok"
    elif os.path.exists(sta_log_path):
        status = "sta_log_only"

    return {
        "module": module,
        "status": status,
        "area": area,
        "inst": inst,
        "max_slack": max_slack,
        "min_slack": min_slack,
        "tns_max": tns_max,
        "tns_min": tns_min,
        "report_dir": report_dir,
    }


def main():
    rows = [parse_module(m) for m in MODULES]
    out_csv = "docs/data/20260304_sta_module_summary.csv"
    os.makedirs("docs/data", exist_ok=True)
    with open(out_csv, "w", encoding="utf-8") as f:
        f.write("module,status,area,inst,max_slack,min_slack,tns_max,tns_min,report_dir\n")
        for r in rows:
            f.write(
                f"{r['module']},{r['status']},"
                f"{'' if r['area'] is None else r['area']},"
                f"{'' if r['inst'] is None else r['inst']},"
                f"{'' if r['max_slack'] is None else r['max_slack']},"
                f"{'' if r['min_slack'] is None else r['min_slack']},"
                f"{'' if r['tns_max'] is None else r['tns_max']},"
                f"{'' if r['tns_min'] is None else r['tns_min']},"
                f"{r['report_dir']}\n"
            )

    print(f"written {out_csv}")
    for r in rows:
        print(r)


if __name__ == "__main__":
    main()
