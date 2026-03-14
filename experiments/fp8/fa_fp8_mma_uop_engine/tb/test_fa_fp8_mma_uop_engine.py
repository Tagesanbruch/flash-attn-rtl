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


def mma_ref(a: int, b: int, acc: int, scale_q1_14: int, round_mode: int, sat_en: int) -> int:
    prod_q8_22 = fp8_e4m3_to_q4_11(a) * fp8_e4m3_to_q4_11(b)
    dot_q8_11 = prod_q8_22 >> 11
    sum_q8_11 = acc + dot_q8_11
    scaled = sum_q8_11 * scale_q1_14
    out = round_shift(scaled, 14, round_mode)
    if sat_en:
        out = min(max(out, -2147483648), 2147483647)
    return s32(out)


async def tick(dut):
    dut.i_clk.value = 0
    await Timer(1, units="ns")
    dut.i_clk.value = 1
    await Timer(1, units="ns")


@cocotb.test()
async def test_fp8_mma_uop_engine_random_stream(dut):
    rng = random.Random(20260315)

    dut.i_clk.value = 0
    dut.i_rst_n.value = 0
    dut.i_valid.value = 0
    dut.i_a_fp8.value = 0
    dut.i_b_fp8.value = 0
    dut.i_acc_q8_11.value = 0
    dut.i_scale_q1_14.value = 1 << 14
    dut.i_round_mode.value = 0
    dut.i_saturate_en.value = 1
    dut.i_ready.value = 1

    for _ in range(5):
        await tick(dut)
    dut.i_rst_n.value = 1

    expected = []
    target = 800
    mismatches = 0
    out_count = 0

    for idx in range(target + 2):
        await tick(dut)

        if idx < target:
            a = rng.randrange(0, 256)
            b = rng.randrange(0, 256)
            acc = s32(rng.randrange(0, 1 << 32))
            scale = rng.randrange(-32768, 32768)
            mode = rng.randrange(0, 2)
            sat = rng.randrange(0, 2)

            dut.i_valid.value = 1
            dut.i_a_fp8.value = a
            dut.i_b_fp8.value = b
            dut.i_acc_q8_11.value = acc & 0xFFFFFFFF
            dut.i_scale_q1_14.value = scale & 0xFFFF
            dut.i_round_mode.value = mode
            dut.i_saturate_en.value = sat

            expected.append(mma_ref(a, b, acc, scale, mode, sat))
        else:
            dut.i_valid.value = 0

        out_fire = int(dut.o_valid.value)
        if out_fire:
            got = s32(int(dut.o_res_q8_11.value))
            exp = expected.pop(0)
            out_count += 1
            if got != exp:
                mismatches += 1

    dut._log.info(
        "fp8_mma_uop_engine: sent=%d out=%d mismatches=%d",
        target,
        out_count,
        mismatches,
    )
    assert out_count == target
    assert mismatches == 0
