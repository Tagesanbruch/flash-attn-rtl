import random

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def test_bf16_to_fp32_directed(dut):
    vectors = [0x0000, 0x8000, 0x3F80, 0xBF80, 0x7F80, 0xFF80, 0x7FC1, 0x0001, 0x007F]

    for x in vectors:
        dut.i_x_bf16.value = x
        await Timer(1, units="ns")
        got = int(dut.o_y_fp32.value) & 0xFFFFFFFF
        ref = (x & 0xFFFF) << 16
        assert got == ref, f"directed mismatch x=0x{x:04x}, got=0x{got:08x}, ref=0x{ref:08x}"


@cocotb.test()
async def test_bf16_to_fp32_random(dut):
    random.seed(20260312)
    for _ in range(2000):
        x = random.randint(0, 0xFFFF)
        dut.i_x_bf16.value = x
        await Timer(1, units="ns")
        got = int(dut.o_y_fp32.value) & 0xFFFFFFFF
        ref = x << 16
        assert got == ref, f"random mismatch x=0x{x:04x}, got=0x{got:08x}, ref=0x{ref:08x}"
