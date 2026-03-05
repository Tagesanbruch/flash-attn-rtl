#!/usr/bin/env python3
import os
import re
import tarfile
import urllib.request
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIST_FILE = ROOT / "scripts" / "paper_download_list_20260305.txt"
PAPERS_DIR = ROOT / "papers"
ARXIV_TEX_DIR = PAPERS_DIR / "arXiv-tex"


def safe_name(name: str) -> str:
    name = re.sub(r"[^a-zA-Z0-9._-]+", "_", name).strip("_")
    return name[:120] if name else "paper"


def read_list(path: Path):
    items = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) != 3:
            continue
        report, title, url = [p.strip() for p in parts]
        items.append((report, title, url))
    return items


def download(url: str, out_path: Path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read()
    out_path.write_bytes(data)


def arxiv_id_from_url(url: str):
    m = re.search(r"arxiv\.org/(?:abs|pdf|src)/([0-9]{4}\.[0-9]{4,5})(?:v\d+)?", url)
    return m.group(1) if m else None


def ensure_pdf_url(url: str):
    aid = arxiv_id_from_url(url)
    if aid:
        return f"https://arxiv.org/pdf/{aid}.pdf", aid
    return url, None


def download_arxiv_src(aid: str):
    src_url = f"https://arxiv.org/src/{aid}"
    out_dir = ARXIV_TEX_DIR / aid
    out_dir.mkdir(parents=True, exist_ok=True)
    archive_path = out_dir / f"{aid}.tar.gz"
    try:
        download(src_url, archive_path)
    except Exception as e:
        print(f"[WARN] arXiv src download failed {aid}: {e}")
        return
    try:
        with tarfile.open(archive_path, "r:gz") as tf:
            tf.extractall(out_dir)
        print(f"[OK] extracted arXiv src: {aid}")
    except Exception as e:
        print(f"[WARN] arXiv src extract failed {aid}: {e}")


def main():
    items = read_list(LIST_FILE)
    print(f"[INFO] loaded items: {len(items)}")

    for report, title, url in items:
        report_dir = PAPERS_DIR / report
        report_dir.mkdir(parents=True, exist_ok=True)

        final_url, aid = ensure_pdf_url(url)
        name = safe_name(title)
        out_pdf = report_dir / f"{name}.pdf"

        if out_pdf.exists() and out_pdf.stat().st_size > 0:
            print(f"[SKIP] exists: {out_pdf}")
        else:
            try:
                download(final_url, out_pdf)
                print(f"[OK] pdf: {title} -> {out_pdf}")
            except Exception as e:
                print(f"[WARN] pdf download failed: {title} | {final_url} | {e}")

        if aid:
            download_arxiv_src(aid)


if __name__ == "__main__":
    main()
