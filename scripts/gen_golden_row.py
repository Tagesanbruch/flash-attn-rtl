#!/usr/bin/env python3
import argparse
import json
import math
import random


def online_row(scores, values):
    m = float("-inf")
    l = 0.0
    acc = 0.0
    for s, v in zip(scores, values):
        m_new = max(m, s)
        l = l * math.exp(m - m_new) + math.exp(s - m_new)
        acc = acc * math.exp(m - m_new) + math.exp(s - m_new) * v
        m = m_new
    return acc / l if l != 0 else 0.0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=256)
    parser.add_argument("--seed", type=int, default=20260302)
    args = parser.parse_args()

    random.seed(args.seed)
    scores = [random.uniform(-4.0, 4.0) for _ in range(args.n)]
    values = [random.uniform(-4.0, 4.0) for _ in range(args.n)]
    out = online_row(scores, values)

    print(json.dumps({
        "seed": args.seed,
        "n": args.n,
        "scores": scores,
        "values": values,
        "out": out,
    }))


if __name__ == "__main__":
    main()
