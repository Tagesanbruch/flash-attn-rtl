import random

import cocotb
from cocotb.triggers import Timer


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


@cocotb.test()
async def test_fp32_to_bf16_directed(dut):
    vectors = [
        0x00000000,
        0x80000000,
        0x3F800000,
        0xBF800000,
        0x7F800000,
        0xFF800000,
        0x7FC00001,
        0x00010000,
        0x007FFFFF,
        0x3F808000,
        0x3F807FFF,
    ]

    for x in vectors:
        dut.i_x_fp32.value = x
        await Timer(1, units="ns")
        got = int(dut.o_y_bf16.value) & 0xFFFF
        ref = fp32_to_bf16_bits(x)
        assert got == ref, f"directed mismatch x=0x{x:08x}, got=0x{got:04x}, ref=0x{ref:04x}"


@cocotb.test()
async def test_fp32_to_bf16_random(dut):
    random.seed(20260312)
    for _ in range(5000):
        x = random.randint(0, 0xFFFFFFFF)
        dut.i_x_fp32.value = x
        await Timer(1, units="ns")
        got = int(dut.o_y_bf16.value) & 0xFFFF
        ref = fp32_to_bf16_bits(x)
        assert got == ref, f"random mismatch x=0x{x:08x}, got=0x{got:04x}, ref=0x{ref:04x}"
