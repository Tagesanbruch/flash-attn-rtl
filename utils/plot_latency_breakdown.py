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
            rows.append((row["category"], int(row["cycles"])))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--title", default="Latency Breakdown")
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    rows = read_rows(Path(args.input))
    cats = [r[0] for r in rows]
    vals = [r[1] for r in rows]

    fig, ax = plt.subplots(figsize=(10, 5))
    y = list(range(len(cats)))
    ax.barh(y, vals)
    ax.set_yticks(y)
    ax.set_yticklabels(cats)
    ax.set_xlabel("cycles")
    ax.set_title(args.title)
    for yi, v in zip(y, vals):
        ax.text(v, yi, f" {v}", va="center", fontsize=9)
    fig.tight_layout()
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.output, dpi=160)
    print("[plot] saved", args.output)


if __name__ == "__main__":
    main()
