#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional


ROOT = Path(__file__).resolve().parents[1]
EXPERIMENTS_DIR = ROOT / "experiments"
LOG_ROOT = ROOT / "logs" / "bf16_module_ae"


@dataclass
class ModuleResult:
    module: str
    seed: int
    samples: int
    mismatches: int
    mae: float
    maxe: float
    extra: str = ""


def run_cmd(cmd: List[str], env: Optional[Dict[str, str]], log_file: Path) -> str:
    log_file.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        cmd,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    log_file.write_text(proc.stdout, encoding="utf-8")
    if proc.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)} (code={proc.returncode})\nsee {log_file}")
    return proc.stdout


def parse_module_stats(text: str, module: str) -> ModuleResult:
    patterns = [
        re.compile(
            r"seed=(?P<seed>\d+)\s+samples=(?P<samples>\d+)\s+mismatches=(?P<mismatches>\d+)\s+MAE=(?P<mae>[-+0-9.eE]+)\s+MaxAE=(?P<maxe>[-+0-9.eE]+)(?P<extra>.*)$"
        ),
    ]
    line = ""
    for ln in text.splitlines():
        if module in ln and "MAE=" in ln and "MaxAE=" in ln:
            line = ln.strip()
    if not line:
        raise RuntimeError(f"cannot parse stats for {module}")

    for pattern in patterns:
        m = pattern.search(line)
        if m:
            return ModuleResult(
                module=module,
                seed=int(m.group("seed")),
                samples=int(m.group("samples")),
                mismatches=int(m.group("mismatches")),
                mae=float(m.group("mae")),
                maxe=float(m.group("maxe")),
                extra=m.groupdict().get("extra", "").strip(),
            )

    raise RuntimeError(f"unrecognized stats line for {module}: {line}")


def parse_stage_decomp(text: str) -> Dict[str, Dict[str, float]]:
    stages: Dict[str, Dict[str, float]] = {}
    pattern = re.compile(
        r"^\s*(dot|score|exp|l|acc|norm)\s+MAE=(?P<mae>[-+0-9.eE]+)\s+MaxAE=(?P<maxe>[-+0-9.eE]+)\s+RMSE=(?P<rmse>[-+0-9.eE]+)"
    )
    for ln in text.splitlines():
        m = pattern.search(ln)
        if m:
            stage = m.group(1)
            stages[stage] = {
                "mae": float(m.group("mae")),
                "maxe": float(m.group("maxe")),
                "rmse": float(m.group("rmse")),
            }
    return stages


def write_summary(seed: int, module_results: List[ModuleResult], stages: Dict[str, Dict[str, float]]) -> None:
    out_dir = LOG_ROOT
    out_dir.mkdir(parents=True, exist_ok=True)

    csv_path = out_dir / f"rtl_vs_cmodel_seed{seed}.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["module", "seed", "samples", "mismatches", "mae", "maxe", "extra"])
        for r in module_results:
            writer.writerow([r.module, r.seed, r.samples, r.mismatches, r.mae, r.maxe, r.extra])

    md_path = out_dir / f"rtl_vs_cmodel_seed{seed}.md"
    lines = []
    lines.append(f"# RTL vs Cmodel 模块AE对照（seed={seed}）")
    lines.append("")
    lines.append("## 1) 模块级 RTL vs Cmodel")
    lines.append("")
    lines.append("| 模块 | samples | mismatches | MAE | MaxE | 备注 |")
    lines.append("|---|---:|---:|---:|---:|---|")
    for r in module_results:
        lines.append(f"| {r.module} | {r.samples} | {r.mismatches} | {r.mae:.6g} | {r.maxe:.6g} | {r.extra or '-'} |")

    lines.append("")
    lines.append("## 2) Cmodel Stage Decomp（同seed）")
    lines.append("")
    lines.append("| Stage | MAE | MaxAE | RMSE |")
    lines.append("|---|---:|---:|---:|")
    for stage in ["dot", "score", "exp", "l", "acc", "norm"]:
        if stage in stages:
            s = stages[stage]
            lines.append(f"| {stage} | {s['mae']:.6g} | {s['maxe']:.6g} | {s['rmse']:.6g} |")

    lines.append("")
    lines.append("## 3) 对照结论")
    lines.append("")
    lines.append("- 模块级 RTL vs cmodel 的 AE 用于验证实现一致性（通常应接近0）。")
    lines.append("- Stage Decomp 是算法/流水线误差分解，和模块级 AE 不是一一映射关系。")
    lines.append("- 若模块级AE≈0但Stage误差大，说明主要是算法近似/量化累积，而非模块实现偏差。")

    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=20260303)
    parser.add_argument("--samples", type=int, default=2000)
    args = parser.parse_args()

    seed = args.seed
    samples = args.samples
    out_dir = LOG_ROOT
    out_dir.mkdir(parents=True, exist_ok=True)

    cmodel_cmd = [
        "make",
        "-C",
        str(ROOT / "cmodel"),
        "build",
    ]
    run_cmd(cmodel_cmd, None, out_dir / f"cmodel_build_seed{seed}.log")

    cmodel_bin = str(ROOT / "cmodel" / "build" / "attention_cmodel")
    cmodel_eval_cmd = [
        cmodel_bin,
        "--s", "256",
        "--d", "64",
        "--tq", "32",
        "--tk", "64",
        "--causal",
        "--input-mode", "bf16",
        "--seed", str(seed),
        "--n-seeds", "1",
        "--run-stage-decomp",
        "--stage-seed", str(seed),
    ]
    cmodel_text = run_cmd(cmodel_eval_cmd, None, out_dir / f"cmodel_stage_seed{seed}.log")
    stages = parse_stage_decomp(cmodel_text)

    modules = [
        ("bf16/fa_fp32_add", "fp32_add"),
        ("bf16/fa_fp32_mul_q16", "fp32_mul_q16"),
        ("bf16/fa_fp32_exp2_pwl", "fp32_exp2_pwl"),
        ("bf16/fa_fp32_recip", "fp32_recip"),
        ("bf16/fa_fp32_to_bf16", "fp32_to_bf16"),
        ("bf16/fa_bf16_to_fp32", "bf16_to_fp32"),
    ]

    module_results: List[ModuleResult] = []
    for mod, key in modules:
        cmd = ["make", "-C", str(EXPERIMENTS_DIR), "verif", f"MOD={mod}", "EXP=base"]
        env = os.environ.copy()
        env["BF16_TEST_SEED"] = str(seed)
        env["BF16_TEST_SAMPLES"] = str(samples)
        env["BF16_AE_DUMP"] = "1"
        env["BF16_AE_LOG_DIR"] = str(out_dir)
        text = run_cmd(cmd, env, out_dir / f"{mod.replace('/', '_')}_seed{seed}.log")
        module_results.append(parse_module_stats(text, key))

    write_summary(seed, module_results, stages)


if __name__ == "__main__":
    main()
