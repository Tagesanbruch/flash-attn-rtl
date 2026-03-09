#!/usr/bin/env python3
import argparse
import os
import re
from pathlib import Path


def parse_chip_area(stat_path: Path):
    text = stat_path.read_text()
    m = re.search(r"Chip area for module '\\[^']+':\s*([0-9.]+)", text)
    return float(m.group(1)) if m else None


def parse_sta(sta_path: Path):
    text = sta_path.read_text()
    matches = re.findall(r"\|\s+([^|]+?)\s+\|\s+core_clock\s+\|\s+max\s+\|\s+([0-9.]+)[rf]?\s+\|\s+([0-9.]+)\s+\|\s+([0-9.\-]+)\s+\|\s+([0-9.\-]+)\s+\|\s+([0-9.]+)\s+\|", text)
    worst = None
    for endpoint, path_delay, path_required, cppr, slack, freq in matches:
        slack_f = float(slack)
        if worst is None or slack_f < worst["slack"]:
            worst = {
                "endpoint": endpoint.strip(),
                "path_delay": float(path_delay),
                "path_required": float(path_required),
                "slack": slack_f,
                "freq": float(freq),
            }
    tns_m = re.search(r"\|\s+core_clock\s+\|\s+max\s+\|\s+([0-9.\-]+)\s+\|", text)
    tns = float(tns_m.group(1)) if tns_m else None
    return worst, tns


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", required=True)
    parser.add_argument("--mods", nargs="+", required=True)
    args = parser.parse_args()

    root = Path("/Volumes/disk/work/flashattn/syn")
    print("| Module | Exp | Area | Worst Slack(ns) | Est Fmax(MHz) | TNS | Endpoint |")
    print("|---|---:|---:|---:|---:|---:|---|")
    for mod in args.mods:
        for exp_dir in sorted(root.glob(f"exp_{mod}_*_{args.date}")):
            exp = exp_dir.name[len(f"exp_{mod}_") : -len(f"_{args.date}")]
            run_dir = exp_dir / f"{mod}-500MHz"
            stat_path = run_dir / "synth_stat.txt"
            sta_path = run_dir / "sta.log"
            if not stat_path.exists():
                continue
            area = parse_chip_area(stat_path)
            if not sta_path.exists():
                print(f"| {mod} | {exp} | {area:.2f} | NA | NA | NA | STA failed / unavailable |")
                continue
            worst, tns = parse_sta(sta_path)
            if worst is None:
                print(f"| {mod} | {exp} | {area:.2f} | NA | NA | {tns or 'NA'} | NA |")
            else:
                print(
                    f"| {mod} | {exp} | {area:.2f} | {worst['slack']:.3f} | {worst['freq']:.1f} | {tns:.3f} | {worst['endpoint']} |"
                )


if __name__ == "__main__":
    main()