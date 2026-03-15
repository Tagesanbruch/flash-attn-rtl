import math
import random

import cocotb
from cocotb.triggers import Timer


def s32(v: int) -> int:
    v &= 0xFFFFFFFF
    return v if v < 0x80000000 else v - 0x100000000


def fp8_e4m3_to_q4_11(x: int) -> int:
    sign = (x >> 7) & 1
    exp = (x >> 3) & 0xF
    frac = x & 0x7
    if exp == 0:
        mag = frac << 2
    elif exp == 0xF:
        mag = 32767
    else:
        mag = (8 + frac) << (exp + 1)
        mag = min(mag, 32767)
    return -mag if sign else mag


def round_shift(v: int, sh: int, mode: int) -> int:
    if sh <= 0:
        return v
    t = v
    if mode == 1:
        if v >= 0:
            t += 1 << (sh - 1)
        else:
            t -= 1 << (sh - 1)
    return t >> sh


def exp2_approx_q0_15(delta_q8_11: int) -> int:
    d = delta_q8_11 >> 8
    if d >= 0:
        return 32767
    if d <= -15:
        return 0
    return 32767 >> (-d)


def q4_11_to_float(x: int) -> float:
    return s32(x) / 2048.0


def ref_ctx(q, k, v, seq_len, head_dim, scale, mode, sat):
    qf = [[fp8_e4m3_to_q4_11(x) for x in row] for row in q]
    kf = [[fp8_e4m3_to_q4_11(x) for x in row] for row in k]
    vf = [[fp8_e4m3_to_q4_11(x) for x in row] for row in v]

    out = [[0 for _ in range(head_dim)] for _ in range(seq_len)]
    for i in range(seq_len):
        scores = []
        row_max = -(1 << 31)
        for j in range(seq_len):
            dot = 0
            for d in range(head_dim):
                dot += qf[i][d] * kf[j][d]
            s = round_shift(dot, 11, mode)
            s = (s * scale) >> 14
            if sat:
                s = min(max(s, -2147483648), 2147483647)
            s = s32(s)
            scores.append(s)
            row_max = max(row_max, s)

        den = 0
        num = [0 for _ in range(head_dim)]
        for j in range(seq_len):
            e = exp2_approx_q0_15(scores[j] - row_max)
            den += e
            for d in range(head_dim):
                num[d] += vf[j][d] * e

        if den != 0:
            for d in range(head_dim):
                out[i][d] = s32(int(num[d] / den))
    return out


def fp32_attention_ref(q, k, v, seq_len, head_dim, scale, causal=False):
    qf = [[q4_11_to_float(fp8_e4m3_to_q4_11(x)) for x in row] for row in q]
    kf = [[q4_11_to_float(fp8_e4m3_to_q4_11(x)) for x in row] for row in k]
    vf = [[q4_11_to_float(fp8_e4m3_to_q4_11(x)) for x in row] for row in v]
    scale_f = scale / (1 << 14)

    out = [[0.0 for _ in range(head_dim)] for _ in range(seq_len)]
    for i in range(seq_len):
        scores = [0.0 for _ in range(seq_len)]
        max_s = -1e30
        for j in range(seq_len):
            dot = 0.0
            for d in range(head_dim):
                dot += qf[i][d] * kf[j][d]
            s = dot * scale_f
            if causal and j > i:
                s = -1e9
            scores[j] = s
            if s > max_s:
                max_s = s

        denom = 0.0
        for j in range(seq_len):
            scores[j] = math.exp(scores[j] - max_s)
            denom += scores[j]

        for j in range(seq_len):
            scores[j] /= denom

        for d in range(head_dim):
            acc = 0.0
            for j in range(seq_len):
                acc += scores[j] * vf[j][d]
            out[i][d] = acc
    return out


def calc_i32_metrics(got, ref):
    total = 0
    count = 0
    max_err = 0
    worst = None
    for i, (g_row, r_row) in enumerate(zip(got, ref)):
        for j, (g, r) in enumerate(zip(g_row, r_row)):
            err = abs(g - r)
            total += err
            count += 1
            if err > max_err:
                max_err = err
                worst = (i, j, g, r)
    mae = (total / count) if count else 0.0
    return mae, max_err, worst


def calc_fp32_metrics(got_i32, ref_fp32):
    total = 0.0
    count = 0
    max_err = 0.0
    worst = None
    for i, (g_row, r_row) in enumerate(zip(got_i32, ref_fp32)):
        for j, (g, r) in enumerate(zip(g_row, r_row)):
            g_f = q4_11_to_float(g)
            err = abs(g_f - r)
            total += err
            count += 1
            if err > max_err:
                max_err = err
                worst = (i, j, g_f, r)
    mae = (total / count) if count else 0.0
    return mae, max_err, worst


async def tick(dut):
    dut.i_clk.value = 0
    await Timer(1, units="ns")
    dut.i_clk.value = 1
    await Timer(1, units="ns")


async def write_mem(dut, sel, addr, data):
    dut.i_wr_en.value = 1
    dut.i_wr_sel.value = sel
    dut.i_wr_addr.value = addr
    dut.i_wr_data.value = data
    await tick(dut)
    dut.i_wr_en.value = 0


async def read_ctx_matrix(dut, seq_len, head_dim, row_stride):
    out = [[0 for _ in range(head_dim)] for _ in range(seq_len)]
    for i in range(seq_len):
        for d in range(head_dim):
            dut.i_rd_addr.value = i * row_stride + d
            await Timer(1, units="ns")
            out[i][d] = s32(int(dut.o_rd_ctx_q4_11.value))
    return out


async def csr_read(dut, addr):
    dut.i_csr_rd_addr.value = addr
    await Timer(1, units="ns")
    return int(dut.o_csr_rd_data.value)


async def collect_perf(dut):
    cycles = int(dut.o_cycle_count.value)
    run_count = int(dut.o_perf_run_count.value)
    busy = int(dut.o_perf_busy_cycles.value)
    rows_done = int(dut.o_perf_rows_done.value)
    score = int(dut.o_perf_score_cycles.value)
    softmax = int(dut.o_perf_softmax_cycles.value)
    pv = int(dut.o_perf_pv_cycles.value)
    ctx_write = int(dut.o_perf_ctx_write_cycles.value)

    perf = {
        "cycles": cycles,
        "run_count": run_count,
        "busy": busy,
        "rows_done": rows_done,
        "score": score,
        "softmax": softmax,
        "pv": pv,
        "ctx_write": ctx_write,
        "dma_rd_cmd": await csr_read(dut, 0x88),
        "dma_rd_beat": await csr_read(dut, 0x8C),
        "dma_wr_cmd": await csr_read(dut, 0x90),
        "dma_wr_beat": await csr_read(dut, 0x94),
        "comp_launch": await csr_read(dut, 0x98),
        "ms_load_q": await csr_read(dut, 0xAC),
        "ms_init": await csr_read(dut, 0xB0),
        "ms_load_k": await csr_read(dut, 0xB4),
        "ms_load_v": await csr_read(dut, 0xB8),
        "ms_compute": await csr_read(dut, 0xBC),
        "ms_norm": await csr_read(dut, 0xC0),
        "ms_write_o": await csr_read(dut, 0xC4),
        "ms_next_q": await csr_read(dut, 0xC8),
        "cs_dp": await csr_read(dut, 0xCC),
        "cs_score": await csr_read(dut, 0xD0),
        "cs_softmax": await csr_read(dut, 0xD4),
        "status": await csr_read(dut, 0x04),
        "csr_cycles": await csr_read(dut, 0x40),
        "csr_run": await csr_read(dut, 0x80),
        "csr_busy": await csr_read(dut, 0x84),
    }
    return perf


def expected_perf(seq_len, head_dim):
    dma_beats = (seq_len * head_dim + 7) // 8
    row_work = 3
    total_cycles = seq_len * row_work + dma_beats * 4
    return {
        "cycles": total_cycles,
        "busy": total_cycles,
        "rows_done": seq_len,
        "score": seq_len,
        "softmax": seq_len,
        "pv": seq_len,
        "ctx_write": seq_len,
        "dma_rd_cmd": 3,
        "dma_rd_beat": 3 * dma_beats,
        "dma_wr_cmd": 1,
        "dma_wr_beat": dma_beats,
        "comp_launch": 1,
        "ms_load_q": dma_beats,
        "ms_init": 1,
        "ms_load_k": dma_beats,
        "ms_load_v": dma_beats,
        "ms_compute": seq_len * row_work,
        "ms_norm": 0,
        "ms_write_o": dma_beats,
        "ms_next_q": max(seq_len - 1, 0),
        "cs_dp": seq_len,
        "cs_score": seq_len,
        "cs_softmax": seq_len,
    }


async def run_case(dut, seq_len, head_dim, seed=20260315, data_min=0, data_max=255, causal=False):
    rng = random.Random(seed)
    row_stride = 64

    scale = 1 << 14
    mode = 0
    sat = 1

    q = [[rng.randrange(data_min, data_max + 1) for _ in range(head_dim)] for _ in range(seq_len)]
    k = [[rng.randrange(data_min, data_max + 1) for _ in range(head_dim)] for _ in range(seq_len)]
    v = [[rng.randrange(data_min, data_max + 1) for _ in range(head_dim)] for _ in range(seq_len)]

    dut.i_clk.value = 0
    dut.i_rst_n.value = 0
    dut.i_start.value = 0
    dut.i_wr_en.value = 0
    dut.i_wr_sel.value = 0
    dut.i_wr_addr.value = 0
    dut.i_wr_data.value = 0
    dut.i_rd_addr.value = 0
    dut.i_csr_rd_addr.value = 0
    dut.i_seq_len.value = seq_len
    dut.i_head_dim.value = head_dim
    dut.i_score_scale_q1_14.value = scale
    dut.i_round_mode.value = mode
    dut.i_saturate_en.value = sat

    for _ in range(3):
        await tick(dut)
    dut.i_rst_n.value = 1

    for i in range(seq_len):
        for d in range(head_dim):
            addr = i * row_stride + d
            await write_mem(dut, 0, addr, q[i][d])
            await write_mem(dut, 1, addr, k[i][d])
            await write_mem(dut, 2, addr, v[i][d])

    ref_fixed = ref_ctx(q, k, v, seq_len, head_dim, scale, mode, sat)
    ref_fp32 = fp32_attention_ref(q, k, v, seq_len, head_dim, scale, causal=causal)

    dut._log.info(
        "fp8 stimulus config: seed=%d range=[%d,%d] causal=%d scale_q1_14=%d",
        seed,
        data_min,
        data_max,
        int(causal),
        scale,
    )

    dut.i_start.value = 1
    await tick(dut)
    dut.i_start.value = 0

    exp = expected_perf(seq_len, head_dim)
    done_seen = False
    for _ in range(exp["cycles"] + 128):
        await tick(dut)
        if int(dut.o_done.value) == 1:
            done_seen = True
            break

    assert done_seen, "Timed out waiting for FP8 run completion"

    got = await read_ctx_matrix(dut, seq_len, head_dim, row_stride)
    perf = await collect_perf(dut)
    mae_i32, max_i32, worst_i32 = calc_i32_metrics(got, ref_fixed)
    mae_fp32, max_fp32, worst_fp32 = calc_fp32_metrics(got, ref_fp32)

    dut._log.info(
        "perf summary: cycles=%d busy=%d rd_cmd=%d rd_beat=%d wr_cmd=%d wr_beat=%d comp_launch=%d exp=%d mul=%d recip_req=%d recip_rsp=%d",
        perf["cycles"],
        perf["busy"],
        perf["dma_rd_cmd"],
        perf["dma_rd_beat"],
        perf["dma_wr_cmd"],
        perf["dma_wr_beat"],
        perf["comp_launch"],
        perf["softmax"],
        perf["score"] + perf["pv"],
        perf["rows_done"],
        perf["rows_done"],
    )
    dut._log.info(
        "perf state cycles: load_q=%d init=%d load_k=%d load_v=%d compute=%d norm=%d write_o=%d next_q=%d dp=%d score=%d softmax=%d",
        perf["ms_load_q"],
        perf["ms_init"],
        perf["ms_load_k"],
        perf["ms_load_v"],
        perf["ms_compute"],
        perf["ms_norm"],
        perf["ms_write_o"],
        perf["ms_next_q"],
        perf["cs_dp"],
        perf["cs_score"],
        perf["cs_softmax"],
    )
    dut._log.info(
        "top numeric check (rtl vs fixed-fp8-model): mae_lsb=%.4f mae=%.6f max_err_lsb=%d max_err=%.6f worst=%s",
        mae_i32,
        mae_i32 / 2048.0,
        max_i32,
        max_i32 / 2048.0,
        worst_i32,
    )
    dut._log.info(
        "top numeric check (rtl vs fp32): mae=%.6f max_err=%.6f worst=%s",
        mae_fp32,
        max_fp32,
        worst_fp32,
    )

    assert perf["run_count"] == 1
    assert perf["cycles"] == exp["cycles"]
    assert perf["busy"] == exp["busy"]
    assert perf["rows_done"] == exp["rows_done"]
    assert perf["score"] == exp["score"]
    assert perf["softmax"] == exp["softmax"]
    assert perf["pv"] == exp["pv"]
    assert perf["ctx_write"] == exp["ctx_write"]
    assert perf["dma_rd_cmd"] == exp["dma_rd_cmd"]
    assert perf["dma_rd_beat"] == exp["dma_rd_beat"]
    assert perf["dma_wr_cmd"] == exp["dma_wr_cmd"]
    assert perf["dma_wr_beat"] == exp["dma_wr_beat"]
    assert perf["comp_launch"] == exp["comp_launch"]
    assert perf["ms_compute"] == exp["ms_compute"]
    assert perf["cs_dp"] == exp["cs_dp"]
    assert perf["cs_score"] == exp["cs_score"]
    assert perf["cs_softmax"] == exp["cs_softmax"]

    assert (perf["status"] & 0x2) != 0
    assert (perf["status"] & 0x1) == 0
    assert perf["csr_cycles"] == perf["cycles"]
    assert perf["csr_run"] == perf["run_count"]
    assert perf["csr_busy"] == perf["busy"]

    assert max_i32 == 0, f"fixed-point mismatch too large: max_err={max_i32}, worst={worst_i32}"


@cocotb.test()
async def test_fp8_attention_core_full_s8_d8(dut):
    await run_case(dut, seq_len=8, head_dim=8, seed=20260315, data_min=0, data_max=255)


@cocotb.test()
async def test_fp8_attention_core_full_s16_d16(dut):
    await run_case(dut, seq_len=16, head_dim=16, seed=20260316, data_min=0, data_max=255)


@cocotb.test()
async def test_fp8_attention_core_full_precision_multiseed_s32_d32(dut):
    for seed in (20260315, 20260316, 20260317):
        await run_case(dut, seq_len=32, head_dim=32, seed=seed, data_min=0, data_max=255)


@cocotb.test()
async def test_fp8_attention_core_full_problem_s256_d64(dut):
    dut._log.info("problem_aligned: note SIM TIME(ns) != o_cycle_count")
    await run_case(dut, seq_len=256, head_dim=64, seed=20260315, data_min=0, data_max=255)
