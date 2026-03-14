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


def pack_u8(vec):
    out = 0
    for i, x in enumerate(vec):
        out |= (x & 0xFF) << (i * 8)
    return out


def softmax_prep_min(score_q8_11: int) -> int:
    score_q8_3 = score_q8_11 >> 8
    if score_q8_3 >= 0:
        return 32767
    if score_q8_3 <= -15:
        return 0
    return 32767 >> (-score_q8_3)


@cocotb.test()
async def test_fp8_attention_core_min_random(dut):
    rng = random.Random(20260315)
    samples = 2000
    mismatches = 0
    score_mis = 0
    weight_mis = 0
    ctx_mis = 0
    first_detail = None

    for _ in range(samples):
        q = [rng.randrange(0, 256) for _ in range(8)]
        k = [rng.randrange(0, 256) for _ in range(8)]
        v = [rng.randrange(0, 256) for _ in range(8)]

        scale = rng.randrange(-32768, 32768)
        mode = rng.randrange(0, 2)
        sat = rng.randrange(0, 2)

        dut.i_q_vec.value = pack_u8(q)
        dut.i_k_vec.value = pack_u8(k)
        dut.i_v_vec.value = pack_u8(v)
        dut.i_score_scale_q1_14.value = scale & 0xFFFF
        dut.i_round_mode.value = mode
        dut.i_saturate_en.value = sat
        await Timer(1, units="ns")

        dot_q8_22 = 0
        for a, b in zip(q, k):
            dot_q8_22 += fp8_e4m3_to_q4_11(a) * fp8_e4m3_to_q4_11(b)
        score_q8_11 = round_shift(dot_q8_22, 11, mode)
        score_scaled = (score_q8_11 * scale) >> 14

        if sat:
            score_scaled = min(max(score_scaled, -2147483648), 2147483647)
        score_scaled = s32(score_scaled)

        weight = softmax_prep_min(score_scaled)

        pv_sum_q4_26 = 0
        for vv in v:
            pv_sum_q4_26 += fp8_e4m3_to_q4_11(vv) * weight
        ctx_q4_11 = s32(pv_sum_q4_26 >> 15)

        got_score = s32(int(dut.o_score_q8_11.value))
        got_weight = s16(int(dut.o_weight_q0_15.value))
        got_ctx = s32(int(dut.o_ctx_q4_11.value))

        bad = False
        if got_score != score_scaled:
            score_mis += 1
            bad = True
        if got_weight != weight:
            weight_mis += 1
            bad = True
        if got_ctx != ctx_q4_11:
            ctx_mis += 1
            bad = True

        if bad:
            mismatches += 1
            if first_detail is None:
                first_detail = {
                    "q": q,
                    "k": k,
                    "v": v,
                    "scale": scale,
                    "mode": mode,
                    "sat": sat,
                    "exp_score": score_scaled,
                    "got_score": got_score,
                    "exp_weight": weight,
                    "got_weight": got_weight,
                    "exp_ctx": ctx_q4_11,
                    "got_ctx": got_ctx,
                }

    dut._log.info(
        "fp8_attention_core_min: samples=%d mismatches=%d score_mis=%d weight_mis=%d ctx_mis=%d first=%s",
        samples,
        mismatches,
        score_mis,
        weight_mis,
        ctx_mis,
        first_detail,
    )
    assert mismatches == 0
