#!/usr/bin/env python3
import argparse
import csv
from pathlib import Path


def read_rows(path: Path):
    m = {}
    with path.open() as f:
        r = csv.DictReader(f)
        for row in r:
            m[row["category"]] = int(row["cycles"])
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--before", required=True)
    ap.add_argument("--after", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    b = read_rows(Path(args.before))
    a = read_rows(Path(args.after))
    cats = sorted(set(b.keys()) | set(a.keys()))

    with Path(args.out).open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["category", "before_cycles", "after_cycles", "delta", "delta_percent"])
        for c in cats:
            bv = b.get(c, 0)
            av = a.get(c, 0)
            d = av - bv
            dp = 100.0 * d / bv if bv else 0.0
            w.writerow([c, bv, av, d, f"{dp:.4f}"])

    print("[compare] written", args.out)


if __name__ == "__main__":
    main()
