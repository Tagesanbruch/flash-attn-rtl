import random
import struct

import cocotb
from cocotb.triggers import Timer


def bits_to_f32(bits: int) -> float:
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


def fp32_cmp_ref(a_bits: int, b_bits: int):
    a_exp = (a_bits >> 23) & 0xFF
    a_frac = a_bits & 0x7FFFFF
    b_exp = (b_bits >> 23) & 0xFF
    b_frac = b_bits & 0x7FFFFF
    a_nan = a_exp == 0xFF and a_frac != 0
    b_nan = b_exp == 0xFF and b_frac != 0
    a_zero = (a_bits & 0x7FFFFFFF) == 0
    b_zero = (b_bits & 0x7FFFFFFF) == 0

    if a_nan and b_nan:
        return dict(gt=0, lt=0, eq=0, unordered=1, max_bits=0x7FC00000)
    if a_nan:
        return dict(gt=0, lt=0, eq=0, unordered=1, max_bits=b_bits)
    if b_nan:
        return dict(gt=0, lt=0, eq=0, unordered=1, max_bits=a_bits)
    if (a_bits == b_bits) or (a_zero and b_zero):
        return dict(gt=0, lt=0, eq=1, unordered=0, max_bits=0 if (a_zero and b_zero) else a_bits)

    a = bits_to_f32(a_bits)
    b = bits_to_f32(b_bits)
    if a > b:
        return dict(gt=1, lt=0, eq=0, unordered=0, max_bits=a_bits)
    return dict(gt=0, lt=1, eq=0, unordered=0, max_bits=b_bits)


async def check_case(dut, a_bits: int, b_bits: int):
    dut.i_a_fp32.value = a_bits
    dut.i_b_fp32.value = b_bits
    await Timer(1, units="ns")

    got = dict(
        gt=int(dut.o_a_gt_b.value),
        lt=int(dut.o_a_lt_b.value),
        eq=int(dut.o_a_eq_b.value),
        unordered=int(dut.o_unordered.value),
        max_bits=int(dut.o_max_fp32.value) & 0xFFFFFFFF,
    )
    ref = fp32_cmp_ref(a_bits, b_bits)
    assert got == ref, f"mismatch a=0x{a_bits:08x}, b=0x{b_bits:08x}, got={got}, ref={ref}"


@cocotb.test()
async def test_fp32_max_compare_directed(dut):
    vectors = [
        (0x3F800000, 0x40000000),
        (0xBF800000, 0x00000000),
        (0x80000000, 0x00000000),
        (0x7F800000, 0x3F800000),
        (0xFF800000, 0x7F800000),
        (0x7FC00001, 0x3F800000),
        (0x7FC00001, 0x7FC00002),
        (0xC1200000, 0xC0800000),
    ]
    for a_bits, b_bits in vectors:
        await check_case(dut, a_bits, b_bits)


@cocotb.test()
async def test_fp32_max_compare_random(dut):
    random.seed(20260312)
    for _ in range(5000):
        a_bits = random.randint(0, 0xFFFFFFFF)
        b_bits = random.randint(0, 0xFFFFFFFF)
        await check_case(dut, a_bits, b_bits)
