import random

import cocotb
from cocotb.triggers import Timer

from bf16.common.cmodel_ref import bf16_to_fp32


@cocotb.test()
async def test_bf16_to_fp32_matches_cmodel(dut):
    rng = random.Random(20260312)
    samples = 2000
    mismatches = 0

    for _ in range(samples):
        x_bits = rng.randrange(0, 1 << 16)
        dut.i_x_bf16.value = x_bits
        await Timer(1, units="ns")
        got = int(dut.o_y_fp32.value)
        exp = bf16_to_fp32(x_bits)
        if got != exp:
            mismatches += 1

    dut._log.info("bf16_to_fp32: samples=%d mismatches=%d", samples, mismatches)
    assert mismatches == 0
