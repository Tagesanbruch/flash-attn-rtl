#!/usr/bin/env python3
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIST = ROOT / "scripts" / "repo_clone_list_20260305.txt"
REF_DIR = ROOT / "ref"


def read_list():
    rows = []
    for line in LIST.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) != 2:
            continue
        rows.append((parts[0].strip(), parts[1].strip()))
    return rows


def main():
    REF_DIR.mkdir(parents=True, exist_ok=True)
    for name, url in read_list():
        dst = REF_DIR / name
        if dst.exists():
            print(f"[SKIP] exists: {dst}")
            continue
        cmd = ["git", "clone", "--depth", "1", url, str(dst)]
        print("[RUN]", " ".join(cmd))
        try:
            subprocess.run(cmd, check=True)
            print(f"[OK] cloned: {name}")
        except subprocess.CalledProcessError as e:
            print(f"[WARN] clone failed: {name} | {url} | code={e.returncode}")


if __name__ == "__main__":
    main()
