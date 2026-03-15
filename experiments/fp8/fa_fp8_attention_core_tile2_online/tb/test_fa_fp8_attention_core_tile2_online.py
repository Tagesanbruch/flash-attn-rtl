import random

import cocotb
from cocotb.triggers import Timer


def s32(v: int) -> int:
    v &= 0xFFFFFFFF
    return v if v < 0x80000000 else v - 0x100000000


def s16(v: int) -> int:
    v &= 0xFFFF
    return v if v < 0x8000 else v - 0x10000


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
            t = v + (1 << (sh - 1))
        else:
            t = v - (1 << (sh - 1))
    return t >> sh


def score_ref(q, k, scale, mode, sat):
    dot_q8_22 = 0
    for a, b in zip(q, k):
        dot_q8_22 += fp8_e4m3_to_q4_11(a) * fp8_e4m3_to_q4_11(b)
    s = round_shift(dot_q8_22, 11, mode)
    s = (s * scale) >> 14
    if sat:
        s = min(max(s, -2147483648), 2147483647)
    return s32(s)


def exp2_approx_q0_15(delta_q8_11):
    d = delta_q8_11 >> 8
    if d >= 0:
        return 32767
    if d <= -15:
        return 0
    return 32767 >> (-d)


def pv_ref(v, w_q0_15):
    acc = 0
    for vv in v:
        acc += fp8_e4m3_to_q4_11(vv) * w_q0_15
    return s32(acc >> 15)


def pack_u8(vec):
    out = 0
    for i, x in enumerate(vec):
        out |= (x & 0xFF) << (i * 8)
    return out


async def tick(dut):
    dut.i_clk.value = 0
    await Timer(1, units="ns")
    dut.i_clk.value = 1
    await Timer(1, units="ns")


@cocotb.test()
async def test_fp8_attention_core_tile2_online_random(dut):
    rng = random.Random(20260315)

    dut.i_clk.value = 0
    dut.i_rst_n.value = 0
    dut.i_cfg_start.value = 0
    dut.i_cfg_round_mode.value = 0
    dut.i_cfg_saturate_en.value = 1
    dut.i_cfg_score_scale_q1_14.value = 1 << 14
    dut.i_q_vec.value = 0
    dut.i_k_tile0.value = 0
    dut.i_v_tile0.value = 0
    dut.i_k_tile1.value = 0
    dut.i_v_tile1.value = 0

    for _ in range(3):
        await tick(dut)
    dut.i_rst_n.value = 1

    samples = 300
    mismatches = 0
    ctx_mis = 0
    done_mis = 0
    perf_mis = 0
    first_detail = None

    for _ in range(samples):
        q = [rng.randrange(0, 256) for _ in range(8)]
        k0 = [rng.randrange(0, 256) for _ in range(8)]
        v0 = [rng.randrange(0, 256) for _ in range(8)]
        k1 = [rng.randrange(0, 256) for _ in range(8)]
        v1 = [rng.randrange(0, 256) for _ in range(8)]
        scale = rng.randrange(-32768, 32768)
        mode = rng.randrange(0, 2)
        sat = rng.randrange(0, 2)

        s0 = score_ref(q, k0, scale, mode, sat)
        s1 = score_ref(q, k1, scale, mode, sat)

        m = max(s0, s1)
        e0 = exp2_approx_q0_15(s0 - m)
        e1 = exp2_approx_q0_15(s1 - m)
        es = e0 + e1
        if es == 0:
            w0 = 16384
            w1 = 16384
        else:
            w0 = (e0 << 15) // es
            w1 = (e1 << 15) // es
            w0 = min(w0, 32767)
            w1 = min(w1, 32767)

        exp_ctx = s32(pv_ref(v0, w0) + pv_ref(v1, w1))

        dut.i_q_vec.value = pack_u8(q)
        dut.i_k_tile0.value = pack_u8(k0)
        dut.i_v_tile0.value = pack_u8(v0)
        dut.i_k_tile1.value = pack_u8(k1)
        dut.i_v_tile1.value = pack_u8(v1)
        dut.i_cfg_round_mode.value = mode
        dut.i_cfg_saturate_en.value = sat
        dut.i_cfg_score_scale_q1_14.value = scale & 0xFFFF

        dut.i_cfg_start.value = 1
        await tick(dut)
        dut.i_cfg_start.value = 0

        for _ in range(5):
            await tick(dut)

        got_ctx = s32(int(dut.o_ctx_sum_q4_11.value))
        got_done = int(dut.o_status_done.value)

        c_cycles = int(dut.o_perf_cycles.value)
        c_score = int(dut.o_perf_score_steps.value)
        c_softmax = int(dut.o_perf_softmax_steps.value)
        c_pv = int(dut.o_perf_pv_steps.value)

        bad = False
        if got_ctx != exp_ctx:
            ctx_mis += 1
            bad = True
        if got_done != 1:
            done_mis += 1
            bad = True
        if c_cycles != 5 or c_score != 2 or c_softmax != 1 or c_pv != 2:
            perf_mis += 1
            bad = True

        if bad:
            mismatches += 1
            if first_detail is None:
                first_detail = {
                    "exp_ctx": exp_ctx,
                    "got_ctx": got_ctx,
                    "got_done": got_done,
                    "perf": [c_cycles, c_score, c_softmax, c_pv],
                    "scale": scale,
                    "mode": mode,
                    "sat": sat,
                    "weights": [w0, w1],
                }

        await tick(dut)

    dut._log.info(
        "fp8_attention_core_tile2_online: samples=%d mismatches=%d ctx_mis=%d done_mis=%d perf_mis=%d first=%s",
        samples,
        mismatches,
        ctx_mis,
        done_mis,
        perf_mis,
        first_detail,
    )
    assert mismatches == 0
