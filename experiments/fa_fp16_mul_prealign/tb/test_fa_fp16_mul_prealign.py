import random

import cocotb
from cocotb.triggers import Timer


def fp16_mul_prealign_ref(a: int, b: int):
    a_sign = (a >> 15) & 0x1
    a_exp = (a >> 10) & 0x1F
    a_frac = a & 0x3FF
    b_sign = (b >> 15) & 0x1
    b_exp = (b >> 10) & 0x1F
    b_frac = b & 0x3FF

    a_is_zero = a_exp == 0 and a_frac == 0
    b_is_zero = b_exp == 0 and b_frac == 0
    a_is_inf = a_exp == 0x1F and a_frac == 0
    b_is_inf = b_exp == 0x1F and b_frac == 0
    a_is_nan = a_exp == 0x1F and a_frac != 0
    b_is_nan = b_exp == 0x1F and b_frac != 0
    a_sub = a_exp == 0 and a_frac != 0
    b_sub = b_exp == 0 and b_frac != 0

    out = {
        "sign": a_sign ^ b_sign,
        "exp_unbiased": 0,
        "mant_prod": 0,
        "is_zero": 0,
        "is_inf": 0,
        "is_nan": 0,
        "a_subnorm": int(a_sub),
        "b_subnorm": int(b_sub),
    }

    if a_is_nan or b_is_nan or ((a_is_inf or b_is_inf) and (a_is_zero or b_is_zero)):
        out["is_nan"] = 1
    elif a_is_inf or b_is_inf:
        out["is_inf"] = 1
    elif a_is_zero or b_is_zero:
        out["is_zero"] = 1
    else:
        a_exp_eff = -14 if a_sub else a_exp - 15
        b_exp_eff = -14 if b_sub else b_exp - 15
        a_mant = a_frac if a_sub else (0x400 | a_frac)
        b_mant = b_frac if b_sub else (0x400 | b_frac)
        out["exp_unbiased"] = a_exp_eff + b_exp_eff
        out["mant_prod"] = a_mant * b_mant
    return out


def sv_signed(value: int, width: int) -> int:
    sign_bit = 1 << (width - 1)
    mask = (1 << width) - 1
    value &= mask
    return (value ^ sign_bit) - sign_bit


async def check_case(dut, a: int, b: int):
    dut.i_a_fp16.value = a
    dut.i_b_fp16.value = b
    await Timer(1, units="ns")

    ref = fp16_mul_prealign_ref(a, b)
    got = {
        "sign": int(dut.o_sign.value),
        "exp_unbiased": sv_signed(int(dut.o_exp_unbiased.value), 11),
        "mant_prod": int(dut.o_mant_prod.value),
        "is_zero": int(dut.o_is_zero.value),
        "is_inf": int(dut.o_is_inf.value),
        "is_nan": int(dut.o_is_nan.value),
        "a_subnorm": int(dut.o_a_subnorm.value),
        "b_subnorm": int(dut.o_b_subnorm.value),
    }
    assert got == ref, f"mismatch a=0x{a:04x}, b=0x{b:04x}, got={got}, ref={ref}"


@cocotb.test()
async def test_fp16_mul_prealign_directed(dut):
    vectors = [
        (0x3C00, 0x4000),
        (0xBC00, 0x4000),
        (0x0000, 0x3C00),
        (0x8000, 0x7C00),
        (0x7C00, 0x3C00),
        (0x7E00, 0x3C00),
        (0x0001, 0x03FF),
        (0x0400, 0x3C00),
    ]

    for a, b in vectors:
        await check_case(dut, a, b)


@cocotb.test()
async def test_fp16_mul_prealign_random(dut):
    random.seed(20260312)
    for _ in range(4000):
        a = random.randint(0, 0xFFFF)
        b = random.randint(0, 0xFFFF)
        await check_case(dut, a, b)
