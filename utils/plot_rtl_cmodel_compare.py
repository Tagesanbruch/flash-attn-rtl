#!/usr/bin/env python3
import argparse
import csv
from pathlib import Path

import matplotlib.pyplot as plt


def read_rows(path: Path):
    rows = []
    with path.open() as f:
        r = csv.DictReader(f)
        for row in r:
            rows.append({
                "category": row["category"],
                "rtl": int(row["rtl_cycles"]),
                "cmodel": int(row["cmodel_cycles"]),
                "model": row.get("cmodel_model", ""),
            })
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--title", default="RTL vs CModel Compute Breakdown")
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    rows = read_rows(Path(args.input))
    cats = [r["category"] for r in rows]
    rtl = [r["rtl"] for r in rows]
    cmodel = [r["cmodel"] for r in rows]

    fig, ax = plt.subplots(figsize=(10, 5.5))
    x = list(range(len(cats)))
    w = 0.38
    ax.bar([i - w / 2 for i in x], rtl, width=w, label="RTL")
    ax.bar([i + w / 2 for i in x], cmodel, width=w, label="CModel")

    ax.set_xticks(x)
    ax.set_xticklabels(cats, rotation=20, ha="right")
    ax.set_ylabel("cycles")
    ax.set_title(args.title)
    ax.legend()

    for i, v in enumerate(rtl):
        ax.text(i - w / 2, v, f"{v}", ha="center", va="bottom", fontsize=8)
    for i, v in enumerate(cmodel):
        ax.text(i + w / 2, v, f"{v}", ha="center", va="bottom", fontsize=8)

    fig.tight_layout()
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.output, dpi=160)
    print("[plot] saved", args.output)


if __name__ == "__main__":
    main()
