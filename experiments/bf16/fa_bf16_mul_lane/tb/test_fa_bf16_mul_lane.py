import ctypes
import random
import struct

import cocotb
from cocotb.triggers import Timer

from bf16.common.golden_models import bf16_mul_reference


def bits_to_f32(bits: int) -> float:
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


def f32_to_bits(value: float) -> int:
    return struct.unpack('>I', struct.pack('>f', ctypes.c_float(value).value))[0]


async def check_case(dut, a: int, b: int):
    dut.i_a_bf16.value = a
    dut.i_b_bf16.value = b
    await Timer(1, units="ns")

    got_fp32 = int(dut.o_y_fp32.value) & 0xFFFFFFFF
    got_bf16 = int(dut.o_y_bf16.value) & 0xFFFF
    ref_fp32, ref_bf16 = bf16_mul_reference(a, b)
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
