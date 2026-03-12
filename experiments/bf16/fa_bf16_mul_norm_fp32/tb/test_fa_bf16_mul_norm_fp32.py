import random

import cocotb
from cocotb.triggers import Timer


def round_shift_right_rne(value: int, shift: int) -> int:
    if shift <= 0:
        return value
    if shift >= 256:
        return 0
    base = value >> shift
    guard = (value >> (shift - 1)) & 0x1
    sticky = 1 if shift > 1 and (value & ((1 << (shift - 1)) - 1)) else 0
    if guard and (sticky or (base & 0x1)):
        base += 1
    return base


def bf16_mul_norm_fp32_ref(sign: int, exp_unbiased: int, mant_prod: int, is_zero: int, is_inf: int, is_nan: int) -> int:
    if is_nan:
        return ((sign & 1) << 31) | 0x7FC00000
    if is_inf:
        return ((sign & 1) << 31) | 0x7F800000
    if is_zero or mant_prod == 0:
        return (sign & 1) << 31

    msb_idx = mant_prod.bit_length() - 1
    exp_norm = exp_unbiased + msb_idx - 14
    sig24 = mant_prod << (23 - msb_idx)

    if exp_norm > 127:
        return ((sign & 1) << 31) | 0x7F800000
    if exp_norm >= -126:
        return ((sign & 1) << 31) | ((exp_norm + 127) << 23) | (sig24 & 0x7FFFFF)

    shift = -126 - exp_norm
    sub_frac = round_shift_right_rne(sig24, shift)
    if sub_frac >= 0x800000:
        return ((sign & 1) << 31) | (1 << 23)
    return ((sign & 1) << 31) | (sub_frac & 0x7FFFFF)


async def check_case(dut, sign: int, exp_unbiased: int, mant_prod: int, is_zero: int, is_inf: int, is_nan: int):
    dut.i_sign.value = sign
    dut.i_exp_unbiased.value = exp_unbiased & 0x7FF
    dut.i_mant_prod.value = mant_prod
    dut.i_is_zero.value = is_zero
    dut.i_is_inf.value = is_inf
    dut.i_is_nan.value = is_nan
    await Timer(1, units="ns")

    got = int(dut.o_y_fp32.value) & 0xFFFFFFFF
    ref = bf16_mul_norm_fp32_ref(sign, exp_unbiased, mant_prod, is_zero, is_inf, is_nan)
    assert got == ref, f"mismatch sign={sign}, exp={exp_unbiased}, mant=0x{mant_prod:04x}, zero={is_zero}, inf={is_inf}, nan={is_nan}, got=0x{got:08x}, ref=0x{ref:08x}"


@cocotb.test()
async def test_bf16_mul_norm_fp32_directed(dut):
    vectors = [(0, 0, 0x4000, 0, 0, 0), (1, 1, 0x4000, 0, 0, 0), (0, -126, 0x4000, 0, 0, 0), (0, -140, 0x4000, 0, 0, 0), (0, 120, 0x7FFF, 0, 0, 0), (1, 0, 0x0000, 1, 0, 0), (0, 0, 0x0000, 0, 1, 0), (0, 0, 0x0000, 0, 0, 1)]

    for vector in vectors:
        await check_case(dut, *vector)


@cocotb.test()
async def test_bf16_mul_norm_fp32_random(dut):
    random.seed(20260312)
    for _ in range(5000):
        sign = random.randint(0, 1)
        kind = random.randint(0, 9)
        if kind == 0:
            await check_case(dut, sign, 0, 0, 1, 0, 0)
        elif kind == 1:
            await check_case(dut, sign, 0, 0, 0, 1, 0)
        elif kind == 2:
            await check_case(dut, sign, 0, 0, 0, 0, 1)
        else:
            exp_unbiased = random.randint(-260, 140)
            mant_prod = random.randint(1, 0xFFFF)
            await check_case(dut, sign, exp_unbiased, mant_prod, 0, 0, 0)
