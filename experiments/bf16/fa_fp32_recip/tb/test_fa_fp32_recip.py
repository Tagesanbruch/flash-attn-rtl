import math
import random
import struct

import cocotb
from cocotb.triggers import Timer


def bits_to_f32(bits: int) -> float:
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


def f32_to_bits(value: float) -> int:
    return struct.unpack('>I', struct.pack('>f', value))[0]


def ref_bits(x_bits: int) -> int:
    sign = (x_bits >> 31) & 0x1
    exp = (x_bits >> 23) & 0xFF
    frac = x_bits & 0x7FFFFF
    if exp == 0xFF and frac != 0:
      return 0x7FC00000
    if (x_bits & 0x7FFFFFFF) == 0:
      return (sign << 31) | 0x7F800000
    if exp == 0xFF and frac == 0:
      return sign << 31
    x = bits_to_f32(x_bits)
    y = 1.0 / x
    return f32_to_bits(y)


def is_finite(bits: int) -> bool:
    return ((bits >> 23) & 0xFF) != 0xFF


async def check_case(dut, x_bits: int, rel_tol: float = 0.015, abs_tol: float = 2e-4):
    dut.i_x_fp32.value = x_bits
    await Timer(1, units="ns")

    got_bits = int(dut.o_y_fp32.value) & 0xFFFFFFFF
    ref = ref_bits(x_bits)
    x_exp = (x_bits >> 23) & 0xFF
    x_frac = x_bits & 0x7FFFFF
    special = x_exp == 0xFF or ((x_bits & 0x7FFFFFFF) == 0)
    if special or not is_finite(ref):
        assert got_bits == ref, f"special mismatch x=0x{x_bits:08x}, got=0x{got_bits:08x}, ref=0x{ref:08x}"
        return

    got = bits_to_f32(got_bits)
    ref_f = bits_to_f32(ref)
    err = abs(got - ref_f)
    limit = max(abs_tol, abs(ref_f) * rel_tol)
    assert err <= limit, f"recip mismatch x=0x{x_bits:08x}, got={got} ref={ref_f} err={err} limit={limit}"


@cocotb.test()
async def test_fp32_recip_directed(dut):
    vectors = [
        0x3F800000,
        0x40000000,
        0x40400000,
        0x3E800000,
        0x44800000,
        0x00000000,
        0x80000000,
        0x7F800000,
        0xFF800000,
        0x7FC00001,
        0xBF800000,
    ]
    for x_bits in vectors:
        await check_case(dut, x_bits)


@cocotb.test()
async def test_fp32_recip_random(dut):
    random.seed(20260312)
    for _ in range(5000):
        if random.random() < 0.1:
            x_bits = random.choice([
                0x00000000,
                0x80000000,
                0x7F800000,
                0xFF800000,
                0x7FC00001,
                0x3F800000,
                0xBF800000,
            ])
        else:
            mag = 2 ** random.uniform(-8.0, 8.0)
            if random.random() < 0.5:
                mag = -mag
            x_bits = f32_to_bits(float(mag))
        await check_case(dut, x_bits)
