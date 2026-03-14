import random

import cocotb
from cocotb.triggers import Timer


def s16(v: int) -> int:
    v &= 0xFFFF
    return v if v < 0x8000 else v - 0x10000


def fp8_e4m3_to_q4_11_raw(x: int):
    sign = (x >> 7) & 1
    exp = (x >> 3) & 0xF
    frac = x & 0x7

    is_zero = exp == 0 and frac == 0
    is_inf = exp == 0xF and frac == 0
    is_nan = exp == 0xF and frac != 0

    if is_zero:
        val = 0
    elif exp == 0:
        val = frac << 2
    elif exp == 0xF:
        val = 32767
    else:
        val = (8 + frac) << (exp + 1)

    if sign:
        val = -val

    return val, is_nan, is_inf, is_zero


def quantize_ref(v: int, round_mode: int, saturate: int, out_frac_bits: int) -> int:
    frac_bits = min(out_frac_bits, 11)
    if frac_bits < 11:
        sh = 11 - frac_bits
        t = v
        if round_mode == 1 and sh > 0:
            if v >= 0:
                t = v + (1 << (sh - 1))
            else:
                t = v - (1 << (sh - 1))
        q = t >> sh
    elif frac_bits > 11:
        q = v << (frac_bits - 11)
    else:
        q = v

    if saturate:
        q = min(max(q, -32768), 32767)
        return q

    return s16(q)


@cocotb.test()
async def test_fp8_e4m3_to_fixed16_cfg_random(dut):
    rng = random.Random(20260315)
    samples = 5000
    mismatches = 0

    for _ in range(samples):
        x = rng.randrange(0, 256)
        round_mode = rng.randrange(0, 2)
        sat = rng.randrange(0, 2)
        out_frac = rng.randrange(0, 12)

        dut.i_fp8.value = x
        dut.i_round_mode.value = round_mode
        dut.i_saturate_en.value = sat
        dut.i_out_frac_bits.value = out_frac
        await Timer(1, units="ns")

        raw, is_nan, is_inf, is_zero = fp8_e4m3_to_q4_11_raw(x)
        exp = quantize_ref(raw, round_mode, sat, out_frac)
        got = s16(int(dut.o_fixed.value))

        got_nan = int(dut.o_is_nan.value)
        got_inf = int(dut.o_is_inf.value)
        got_zero = int(dut.o_is_zero.value)

        if got != exp or got_nan != int(is_nan) or got_inf != int(is_inf) or got_zero != int(is_zero):
            mismatches += 1

    dut._log.info("fp8_e4m3_to_fixed16_cfg random: samples=%d mismatches=%d", samples, mismatches)
    assert mismatches == 0


@cocotb.test()
async def test_fp8_e4m3_to_fixed16_cfg_corner_cases(dut):
    vectors = [
        (0x00, 0, 1, 11),  # +0
        (0x80, 0, 1, 11),  # -0
        (0x7F, 0, 1, 11),  # +NaN
        (0xFF, 0, 1, 11),  # -NaN
        (0x78, 0, 1, 11),  # +Inf
        (0xF8, 0, 1, 11),  # -Inf
        (0x01, 0, 1, 11),  # min subnormal
        (0x08, 0, 1, 11),  # min normal
        (0x77, 1, 1, 8),   # max finite with rounding
        (0xF7, 1, 1, 8),   # min finite with rounding
    ]

    for x, round_mode, sat, out_frac in vectors:
        dut.i_fp8.value = x
        dut.i_round_mode.value = round_mode
        dut.i_saturate_en.value = sat
        dut.i_out_frac_bits.value = out_frac
        await Timer(1, units="ns")

        raw, is_nan, is_inf, is_zero = fp8_e4m3_to_q4_11_raw(x)
        exp = quantize_ref(raw, round_mode, sat, out_frac)
        got = s16(int(dut.o_fixed.value))

        assert got == exp
        assert int(dut.o_is_nan.value) == int(is_nan)
        assert int(dut.o_is_inf.value) == int(is_inf)
        assert int(dut.o_is_zero.value) == int(is_zero)
