import ctypes
import random
import struct

import cocotb
from cocotb.triggers import Timer


def bits_to_f32(bits: int) -> float:
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


def f32_to_bits(value: float) -> int:
    return struct.unpack('>I', struct.pack('>f', ctypes.c_float(value).value))[0]


def bf16_to_fp32_bits(x: int) -> int:
    return (x & 0xFFFF) << 16


def fp32_to_bf16_bits(x: int) -> int:
    sign = (x >> 31) & 0x1
    exp = (x >> 23) & 0xFF
    frac = x & 0x7FFFFF
    if exp == 0xFF and frac != 0:
        payload = (frac >> 16) & 0x7F
        if payload == 0:
            payload = 0x40
        return (sign << 15) | (0xFF << 7) | payload
    rounded = (x + 0x7FFF + ((x >> 16) & 1)) & 0xFFFFFFFF
    return (rounded >> 16) & 0xFFFF


def mul_ref(a_bf16: int, b_bf16: int):
    a_f32 = bits_to_f32(bf16_to_fp32_bits(a_bf16))
    b_f32 = bits_to_f32(bf16_to_fp32_bits(b_bf16))
    prod_bits = f32_to_bits(a_f32 * b_f32)
    exp = (prod_bits >> 23) & 0xFF
    frac = prod_bits & 0x7FFFFF
    if exp == 0xFF and frac != 0:
        sign = ((a_bf16 >> 15) ^ (b_bf16 >> 15)) & 0x1
        prod_bits = (sign << 31) | 0x7FC00000
    return prod_bits, fp32_to_bf16_bits(prod_bits)


async def check_case(dut, a: int, b: int):
    dut.i_a_bf16.value = a
    dut.i_b_bf16.value = b
    await Timer(1, units="ns")

    got_fp32 = int(dut.o_y_fp32.value) & 0xFFFFFFFF
    got_bf16 = int(dut.o_y_bf16.value) & 0xFFFF
    ref_fp32, ref_bf16 = mul_ref(a, b)
    assert got_fp32 == ref_fp32, f"fp32 mismatch a=0x{a:04x}, b=0x{b:04x}, got=0x{got_fp32:08x}, ref=0x{ref_fp32:08x}"
    assert got_bf16 == ref_bf16, f"bf16 mismatch a=0x{a:04x}, b=0x{b:04x}, got=0x{got_bf16:04x}, ref=0x{ref_bf16:04x}"


@cocotb.test()
async def test_bf16_mul_lane_directed(dut):
    vectors = [
        (0x3F80, 0x4000),
        (0xBF80, 0x4000),
        (0x0000, 0x3F80),
        (0x7F80, 0x3F80),
        (0xFF80, 0x3F80),
        (0x7FC1, 0x3F80),
        (0x0001, 0x007F),
        (0x3FC0, 0x3FC0),
    ]
    for a, b in vectors:
        await check_case(dut, a, b)


@cocotb.test()
async def test_bf16_mul_lane_random(dut):
    random.seed(20260312)
    for _ in range(5000):
        a = random.randint(0, 0xFFFF)
        b = random.randint(0, 0xFFFF)
        await check_case(dut, a, b)
