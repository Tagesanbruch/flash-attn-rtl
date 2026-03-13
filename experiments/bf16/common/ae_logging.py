from __future__ import annotations

import csv
import math
import os
from pathlib import Path
from typing import Dict, Iterable, List

from bf16.common.cocotb_utils import bits_to_f32


def resolve_seed(default_seed: int = 20260312) -> int:
    return int(os.environ.get("BF16_TEST_SEED", str(default_seed)))


def resolve_samples(default_samples: int = 2000) -> int:
    return int(os.environ.get("BF16_TEST_SAMPLES", str(default_samples)))


def resolve_log_dir() -> Path:
    return Path(os.environ.get("BF16_AE_LOG_DIR", "logs/bf16_module_ae")).resolve()


def should_dump_rows() -> bool:
    return os.environ.get("BF16_AE_DUMP", "1") not in {"0", "false", "False"}


def float_abs_error(a_bits: int, b_bits: int) -> float:
    if (a_bits & 0xFFFFFFFF) == (b_bits & 0xFFFFFFFF):
        return 0.0
    av = bits_to_f32(a_bits)
    bv = bits_to_f32(b_bits)
    if math.isnan(av) and math.isnan(bv):
        return 0.0
    if math.isinf(av) and math.isinf(bv) and ((av > 0) == (bv > 0)):
        return 0.0
    if not (math.isfinite(av) and math.isfinite(bv)):
        return float("inf")
    return abs(av - bv)


def write_case_csv(module: str, seed: int, rows: Iterable[Dict[str, object]]) -> Path:
    out_dir = resolve_log_dir()
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{module}_seed{seed}.csv"
    rows_list: List[Dict[str, object]] = list(rows)
    if not rows_list:
        with out_path.open("w", encoding="utf-8") as f:
            f.write("idx\n")
        return out_path

    fieldnames = list(rows_list[0].keys())
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows_list)
    return out_path
