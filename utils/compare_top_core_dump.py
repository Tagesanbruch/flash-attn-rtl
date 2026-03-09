import csv
from pathlib import Path


def load_matrix(path: Path):
    with path.open() as f:
        return [[int(x) for x in row] for row in csv.reader(f)]


def main():
    base = Path("docs/data/top_core_diff")
    top = load_matrix(base / "top" / "O_top_q8_8.csv")
    core = load_matrix(base / "core" / "O_rtl_q8_8.csv")

    s = len(top)
    d = len(top[0]) if s else 0

    maxe = 0
    worst = None
    total = 0
    row_hist = []
    for i in range(s):
        row_max = 0
        row_sum = 0
        nz = 0
        for j in range(d):
            e = abs(top[i][j] - core[i][j])
            total += e
            row_sum += e
            if e:
                nz += 1
            if e > row_max:
                row_max = e
            if e > maxe:
                maxe = e
                worst = (i, j, top[i][j], core[i][j])
        row_hist.append((i, row_max, row_sum, nz))

    print(f"mae_lsb={total / (s * d):.6f}")
    print(f"maxe_lsb={maxe} worst={worst}")
    print(f"rows_with_any_error={sum(1 for _, rm, _, _ in row_hist if rm != 0)}")
    print("top_rows_by_row_sum:")
    for item in sorted(row_hist, key=lambda x: (x[2], x[1]), reverse=True)[:20]:
        print(item)

    col_hist = []
    for j in range(d):
        col_max = 0
        col_sum = 0
        nz = 0
        for i in range(s):
            e = abs(top[i][j] - core[i][j])
            col_sum += e
            if e:
                nz += 1
            if e > col_max:
                col_max = e
        col_hist.append((j, col_max, col_sum, nz))

    print("top_cols_by_col_sum:")
    for item in sorted(col_hist, key=lambda x: (x[2], x[1]), reverse=True)[:20]:
        print(item)

    lane_hist = []
    for lane in range(8):
        lane_sum = 0
        lane_max = 0
        lane_nz = 0
        lane_cnt = 0
        for i in range(s):
            for j in range(lane, d, 8):
                e = abs(top[i][j] - core[i][j])
                lane_sum += e
                lane_cnt += 1
                if e:
                    lane_nz += 1
                if e > lane_max:
                    lane_max = e
        lane_hist.append((lane, lane_max, lane_sum, lane_nz, lane_cnt, lane_sum / lane_cnt))

    print("lane_hist_by_mod8:")
    for item in lane_hist:
        print(item)

    block_hist = []
    for blk in range((s + 31) // 32):
        r0 = blk * 32
        r1 = min(s, r0 + 32)
        blk_sum = 0
        blk_max = 0
        blk_nz = 0
        blk_cnt = 0
        for i in range(r0, r1):
            for j in range(d):
                e = abs(top[i][j] - core[i][j])
                blk_sum += e
                blk_cnt += 1
                if e:
                    blk_nz += 1
                if e > blk_max:
                    blk_max = e
        block_hist.append((blk, blk_max, blk_sum, blk_nz, blk_cnt, blk_sum / blk_cnt))

    print("row_block_hist_by_32:")
    for item in block_hist:
        print(item)


if __name__ == "__main__":
    main()
