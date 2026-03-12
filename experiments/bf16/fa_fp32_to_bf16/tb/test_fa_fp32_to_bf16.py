import random

import cocotb
from cocotb.triggers import Timer

from bf16.common.cmodel_ref import fp32_to_bf16
from bf16.common.cocotb_utils import rand_fp32_bits


@cocotb.test()
async def test_fp32_to_bf16_matches_cmodel(dut):
    rng = random.Random(20260312)
    samples = 2000
    mismatches = 0

    for _ in range(samples):
        x_bits = rand_fp32_bits(rng, -16.0, 16.0)
        dut.i_x_fp32.value = x_bits
        await Timer(1, units="ns")
        got = int(dut.o_y_bf16.value)
        exp = fp32_to_bf16(x_bits)
        if got != exp:
            mismatches += 1

    dut._log.info("fp32_to_bf16: samples=%d mismatches=%d", samples, mismatches)
    assert mismatches == 0
