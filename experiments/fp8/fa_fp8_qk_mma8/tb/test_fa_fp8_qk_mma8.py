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


def round_shift(v: int, sh: int, round_mode: int) -> int:
    if sh <= 0:
        return v
    t = v
    if round_mode == 1:
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


@cocotb.test()
async def test_fp8_qk_mma8_random(dut):
    rng = random.Random(20260315)
    samples = 4000
    mismatches = 0

    for _ in range(samples):
        q = [rng.randrange(0, 256) for _ in range(8)]
        k = [rng.randrange(0, 256) for _ in range(8)]
        mode = rng.randrange(0, 2)
        sat = rng.randrange(0, 2)

        dut.i_q_vec.value = pack_u8(q)
        dut.i_k_vec.value = pack_u8(k)
        dut.i_round_mode.value = mode
        dut.i_saturate_en.value = sat
        await Timer(1, units="ns")

        acc = 0
        for a, b in zip(q, k):
            acc += fp8_e4m3_to_q4_11(a) * fp8_e4m3_to_q4_11(b)
        exp = round_shift(acc, 11, mode)
        if sat:
            exp = min(max(exp, -2147483648), 2147483647)
        exp = s32(exp)

        got = s32(int(dut.o_score_q8_11.value))
        if got != exp:
            mismatches += 1

    dut._log.info("fp8_qk_mma8: samples=%d mismatches=%d", samples, mismatches)
    assert mismatches == 0
