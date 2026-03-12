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
    if exp == 0xFF and sign == 0:
        return 0x7F800000
    if exp == 0xFF and sign == 1:
        return 0x00000000

    x = bits_to_f32(x_bits)
    if x > 15.99609375:
        return 0x7F800000
    x = max(x, -16.0)
    return f32_to_bits(2.0 ** x)


def is_special(bits: int) -> bool:
    return ((bits >> 23) & 0xFF) == 0xFF or bits == 0


async def check_case(dut, x_bits: int, rel_tol: float = 0.02, abs_tol: float = 2e-4):
    dut.i_x_fp32.value = x_bits
    await Timer(1, units="ns")

    got_bits = int(dut.o_y_fp32.value) & 0xFFFFFFFF
    ref = ref_bits(x_bits)
    if is_special(ref):
        assert got_bits == ref, f"special mismatch x=0x{x_bits:08x}, got=0x{got_bits:08x}, ref=0x{ref:08x}"
        return

    got = bits_to_f32(got_bits)
    ref_f = bits_to_f32(ref)
    err = abs(got - ref_f)
    limit = max(abs_tol, abs(ref_f) * rel_tol)
    assert err <= limit, f"exp2 mismatch x=0x{x_bits:08x}, got={got}, ref={ref_f}, err={err}, limit={limit}"


@cocotb.test()
async def test_fp32_exp2_pwl_directed(dut):
    vectors = [
        f32_to_bits(-4.0),
        f32_to_bits(-1.5),
        f32_to_bits(-1.0),
        f32_to_bits(-0.5),
        f32_to_bits(0.0),
        f32_to_bits(1.0),
        f32_to_bits(4.0),
        0x7F800000,
        0xFF800000,
        0x7FC00001,
    ]
    for x_bits in vectors:
        await check_case(dut, x_bits)


@cocotb.test()
async def test_fp32_exp2_pwl_random(dut):
    random.seed(20260312)
    for _ in range(5000):
        if random.random() < 0.1:
            x_bits = random.choice([
                0x7F800000,
                0xFF800000,
                0x7FC00001,
                f32_to_bits(-16.0),
                f32_to_bits(0.0),
                f32_to_bits(8.0),
            ])
        else:
            x_bits = f32_to_bits(random.uniform(-16.0, 15.5))
        await check_case(dut, x_bits)
