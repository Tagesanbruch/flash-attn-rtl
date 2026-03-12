import random

import cocotb
from cocotb.triggers import Timer


def fp16_to_fp32_bits(x: int) -> int:
    sign = (x >> 15) & 0x1
    exp = (x >> 10) & 0x1F
    frac = x & 0x3FF

    if exp == 0x1F:
        return (sign << 31) | (0xFF << 23) | (frac << 13)
    if exp == 0:
        if frac == 0:
            return sign << 31
        msb_idx = max(i for i in range(10) if (frac >> i) & 1)
        sig24 = frac << (23 - msb_idx)
        exp32 = msb_idx + 103
        return (sign << 31) | (exp32 << 23) | (sig24 & 0x7FFFFF)
    exp32 = exp + 112
    return (sign << 31) | (exp32 << 23) | (frac << 13)


@cocotb.test()
async def test_fp16_to_fp32_directed(dut):
    vectors = [
        0x0000,
        0x8000,
        0x3C00,
        0xBC00,
        0x7C00,
        0xFC00,
        0x7E00,
        0x0001,
        0x03FF,
        0x3555,
    ]

    for x in vectors:
        dut.i_x_fp16.value = x
        await Timer(1, units="ns")
        got = int(dut.o_y_fp32.value) & 0xFFFFFFFF
        ref = fp16_to_fp32_bits(x)
        assert got == ref, f"directed mismatch x=0x{x:04x}, got=0x{got:08x}, ref=0x{ref:08x}"


@cocotb.test()
async def test_fp16_to_fp32_random(dut):
    random.seed(20260312)
    for _ in range(4000):
        x = random.randint(0, 0xFFFF)
        dut.i_x_fp16.value = x
        await Timer(1, units="ns")
        got = int(dut.o_y_fp32.value) & 0xFFFFFFFF
        ref = fp16_to_fp32_bits(x)
        assert got == ref, f"random mismatch x=0x{x:04x}, got=0x{got:08x}, ref=0x{ref:08x}"
