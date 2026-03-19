#!/usr/bin/env python3
import re
from collections import defaultdict
from pathlib import Path

p = Path('/Volumes/disk/work/flashattn/inference/native/logs/cmodel_real_diff.log')
rows = []
for ln in p.read_text(errors='ignore').splitlines():
    m = re.search(
        r'layer=(\d+) pos=(\d+) head=(\d+) max_abs_lsb=(\d+) idx=(\d+) '
        r'm15=(-?\d+) m14=(-?\d+) qmax=(\d+) kmax=(\d+) vmax=(\d+)',
        ln,
    )
    if not m:
        continue
    l, pos, h, mad, idx, m15, m14, qm, km, vm = map(int, m.groups())
    rows.append((mad, l, pos, h, idx, m15, m14, qm, km, vm))

print('rows', len(rows))
rows.sort(reverse=True)
print('top10')
for r in rows[:10]:
    print(r)

ps = defaultdict(lambda: [0, 0])
for mad, _l, pos, _h, *_ in rows:
    ps[pos][0] += mad
    ps[pos][1] += 1

pos_rank = sorted(
    [(pos, s / c if c else 0.0, s, c) for pos, (s, c) in ps.items()],
    key=lambda x: x[1],
    reverse=True,
)
print('pos_avg_top', pos_rank[:10])

ls = defaultdict(lambda: [0, 0])
for mad, l, _pos, _h, *_ in rows:
    ls[l][0] += mad
    ls[l][1] += 1

layer_rank = sorted(
    [(l, s / c if c else 0.0, s, c) for l, (s, c) in ls.items()],
    key=lambda x: x[1],
    reverse=True,
)
print('layer_avg_top', layer_rank[:10])
