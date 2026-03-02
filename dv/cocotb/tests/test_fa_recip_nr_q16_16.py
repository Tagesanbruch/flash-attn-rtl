import random
import cocotb
from cocotb.triggers import Timer

from fp_ref import recip_q16_16


@cocotb.test()
async def test_recip_directed(dut):
    vectors = [
        0,
        1 << 16,
        2 << 16,
        3 << 16,
        (1 << 16) // 2,
        0x00010000,
        0x7FFFFFFF,
    ]

    for x in vectors:
        dut.i_x_q16_16.value = x & 0xFFFFFFFF
        await Timer(1, units="ns")
        got = int(dut.o_recip_q16_16.value) & 0xFFFFFFFF
        exp = recip_q16_16(x)
        assert got == exp, f"directed mismatch x={x}, got={hex(got)}, exp={hex(exp)}"


@cocotb.test()
async def test_recip_random(dut):
    random.seed(20260302)
    for _ in range(500):
        x = random.randint(1, 0xFFFFFFFF)
        dut.i_x_q16_16.value = x
        await Timer(1, units="ns")
        got = int(dut.o_recip_q16_16.value) & 0xFFFFFFFF
        exp = recip_q16_16(x)
        assert got == exp, f"random mismatch x={x}, got={hex(got)}, exp={hex(exp)}"
