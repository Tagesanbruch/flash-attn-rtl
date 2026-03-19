#!/usr/bin/env python3
import re
import csv
from pathlib import Path

src = Path('/Volumes/disk/work/flashattn/inference/native/logs/dpi_head_summary.log')
out_csv = Path('/Volumes/disk/work/flashattn/inference/native/logs/head_heatmap_pos1.csv')
out_md = Path('/Volumes/disk/work/flashattn/docs/20260319_head_heatmap_pos1.md')

rows = []
for line in src.read_text(errors='ignore').splitlines():
    m = re.search(
        r'head_summary pos=(\d+) head=(\d+) rtl_maxabs=(\d+) ref_maxabs=(\d+) '
        r'max_abs_lsb=(\d+) max_idx=(\d+) rtl=(-?\d+) ref=(-?\d+)',
        line,
    )
    if not m:
        continue
    pos, head, rtl_max, ref_max, mad, max_idx, rtl, ref = map(int, m.groups())
    if pos == 1:
        rows.append((head, rtl_max, ref_max, mad, max_idx, rtl, ref))

n_heads = 14
matrix = []
for i in range(0, len(rows), n_heads):
    chunk = rows[i:i + n_heads]
    if len(chunk) == n_heads:
        matrix.append(chunk)

out_csv.parent.mkdir(parents=True, exist_ok=True)
out_md.parent.mkdir(parents=True, exist_ok=True)

with out_csv.open('w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['layer'] + [f'h{h}' for h in range(n_heads)])
    for layer, chunk in enumerate(matrix):
        values = [''] * n_heads
        for head, _rtl_max, _ref_max, mad, _max_idx, _rtl, _ref in chunk:
            values[head] = mad
        w.writerow([layer] + values)

hotspots = []
for layer, chunk in enumerate(matrix):
    for head, rtl_max, ref_max, mad, max_idx, rtl, ref in chunk:
        ratio = (rtl_max / ref_max) if ref_max else 999.0
        hotspots.append((mad, layer, head, rtl_max, ref_max, ratio, max_idx, rtl, ref))
hotspots.sort(reverse=True)

with out_md.open('w') as f:
    f.write('# 2026-03-19 pos=1 头级误差热力图\n\n')
    f.write('- 来源: inference/native/logs/dpi_head_summary.log\n')
    f.write('- 过滤: pos=1\n')
    f.write(f'- 解析条数: {len(rows)} (期望 24*14=336)\n')
    f.write('- 矩阵CSV: inference/native/logs/head_heatmap_pos1.csv\n\n')

    f.write('## Top 20 热点\n\n')
    f.write('|rank|max_abs_lsb|layer|head|rtl_maxabs|ref_maxabs|amp_ratio|idx|rtl|ref|\n')
    f.write('|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n')
    for rank, item in enumerate(hotspots[:20], 1):
        mad, layer, head, rtl_max, ref_max, ratio, max_idx, rtl, ref = item
        f.write(
            f'|{rank}|{mad}|{layer}|{head}|{rtl_max}|{ref_max}|{ratio:.2f}|{max_idx}|{rtl}|{ref}|\n'
        )

    f.write('\n## 每层每头 max_abs_lsb（紧凑表）\n\n')
    f.write('|layer|' + '|'.join([f'h{h}' for h in range(n_heads)]) + '|\n')
    f.write('|' + '|'.join(['---:'] * (n_heads + 1)) + '|\n')
    for layer, chunk in enumerate(matrix):
        values = ['0'] * n_heads
        for head, _rtl_max, _ref_max, mad, _max_idx, _rtl, _ref in chunk:
            values[head] = str(mad)
        f.write('|' + str(layer) + '|' + '|'.join(values) + '|\n')

print(f'rows_pos1={len(rows)} layers={len(matrix)}')
print(f'wrote {out_csv}')
print(f'wrote {out_md}')
