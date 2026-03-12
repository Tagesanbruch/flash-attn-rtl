import random

import cocotb
from cocotb.triggers import Timer

from bf16.common.cmodel_ref import fp32_exp2_pwl
from bf16.common.cocotb_utils import bits_to_f32, rand_fp32_bits


@cocotb.test()
async def test_fp32_exp2_pwl_matches_cmodel(dut):
    rng = random.Random(20260312)
    samples = 2000
    mismatches = 0
    errs = []

    for _ in range(samples):
        x_bits = rand_fp32_bits(rng, -16.0, 4.0)
        dut.i_x_fp32.value = x_bits
        await Timer(1, units="ns")
        got = int(dut.o_y_fp32.value)
        exp = fp32_exp2_pwl(x_bits)
        if got != exp:
            mismatches += 1
        errs.append(abs(bits_to_f32(got) - bits_to_f32(exp)))

    mae = sum(errs) / len(errs)
    maxe = max(errs) if errs else 0.0
    dut._log.info("fp32_exp2_pwl: samples=%d mismatches=%d mae=%.6g maxe=%.6g", samples, mismatches, mae, maxe)
    assert mismatches == 0
