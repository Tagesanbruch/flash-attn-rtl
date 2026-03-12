import random

import cocotb
from cocotb.triggers import Timer

from bf16.common.cmodel_ref import fp32_mul_q16
from bf16.common.cocotb_utils import bits_to_f32, rand_fp32_bits


@cocotb.test()
async def test_fp32_mul_q16_matches_cmodel(dut):
    rng = random.Random(20260312)
    samples = 2000
    mismatches = 0
    errs = []

    for _ in range(samples):
        a_bits = rand_fp32_bits(rng, -4.0, 4.0)
        b_bits = rand_fp32_bits(rng, -4.0, 4.0)
        dut.i_a_fp32.value = a_bits
        dut.i_b_fp32.value = b_bits
        await Timer(1, units="ns")
        got = int(dut.o_y_fp32.value)
        exp = fp32_mul_q16(a_bits, b_bits)
        if got != exp:
            mismatches += 1
        errs.append(abs(bits_to_f32(got) - bits_to_f32(exp)))

    mae = sum(errs) / len(errs)
    maxe = max(errs) if errs else 0.0
    dut._log.info("fp32_mul_q16: samples=%d mismatches=%d mae=%.6g maxe=%.6g", samples, mismatches, mae, maxe)
    assert mismatches == 0
