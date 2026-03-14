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
            t = v + (1 << (sh - 1))
        else:
            t = v - (1 << (sh - 1))
    return t >> sh


def pack_u8(vec):
    out = 0
    for i, x in enumerate(vec):
        out |= (x & 0xFF) << (i * 8)
    return out


def tile_ctx_ref(q, k, v, scale, mode, sat):
    dot_q8_22 = 0
    for a, b in zip(q, k):
        dot_q8_22 += fp8_e4m3_to_q4_11(a) * fp8_e4m3_to_q4_11(b)
    score_q8_11 = round_shift(dot_q8_22, 11, mode)
    score_scaled = (score_q8_11 * scale) >> 14
    if sat:
        score_scaled = min(max(score_scaled, -2147483648), 2147483647)
    score_scaled = s32(score_scaled)

    score_q8_3 = score_scaled >> 8
    if score_q8_3 >= 0:
        weight = 32767
    elif score_q8_3 <= -15:
        weight = 0
    else:
        weight = 32767 >> (-score_q8_3)

    pv_sum_q4_26 = 0
    for vv in v:
        pv_sum_q4_26 += fp8_e4m3_to_q4_11(vv) * weight
    return s32(pv_sum_q4_26 >> 15)


async def tick(dut):
    dut.i_clk.value = 0
    await Timer(1, units="ns")
    dut.i_clk.value = 1
    await Timer(1, units="ns")


@cocotb.test()
async def test_fp8_attention_core_tile2_pipeline_random(dut):
    rng = random.Random(20260315)
    samples = 500
    mismatches = 0

    dut.i_clk.value = 0
    dut.i_rst_n.value = 0
    dut.i_start.value = 0
    dut.i_q_vec.value = 0
    dut.i_k_tile0.value = 0
    dut.i_k_tile1.value = 0
    dut.i_v_tile0.value = 0
    dut.i_v_tile1.value = 0
    dut.i_score_scale_q1_14.value = 1 << 14
    dut.i_round_mode.value = 0
    dut.i_saturate_en.value = 1

    for _ in range(3):
        await tick(dut)
    dut.i_rst_n.value = 1

    for _ in range(samples):
        q = [rng.randrange(0, 256) for _ in range(8)]
        k0 = [rng.randrange(0, 256) for _ in range(8)]
        v0 = [rng.randrange(0, 256) for _ in range(8)]
        k1 = [rng.randrange(0, 256) for _ in range(8)]
        v1 = [rng.randrange(0, 256) for _ in range(8)]
        scale = rng.randrange(-32768, 32768)
        mode = rng.randrange(0, 2)
        sat = rng.randrange(0, 2)

        dut.i_q_vec.value = pack_u8(q)
        dut.i_k_tile0.value = pack_u8(k0)
        dut.i_v_tile0.value = pack_u8(v0)
        dut.i_k_tile1.value = pack_u8(k1)
        dut.i_v_tile1.value = pack_u8(v1)
        dut.i_score_scale_q1_14.value = scale & 0xFFFF
        dut.i_round_mode.value = mode
        dut.i_saturate_en.value = sat

        exp_ctx = s32(tile_ctx_ref(q, k0, v0, scale, mode, sat) + tile_ctx_ref(q, k1, v1, scale, mode, sat))

        dut.i_start.value = 1
        await tick(dut)
        dut.i_start.value = 0

        # RUN0
        await tick(dut)
        # RUN1
        await tick(dut)

        got = s32(int(dut.o_ctx_sum_q4_11.value))
        done = int(dut.o_done.value)
        if done != 1 or got != exp_ctx:
            mismatches += 1

        # return to IDLE
        await tick(dut)

    dut._log.info("fp8_attention_core_tile2_pipeline: samples=%d mismatches=%d", samples, mismatches)
    assert mismatches == 0
