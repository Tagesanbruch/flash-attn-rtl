import random

import cocotb
from cocotb.triggers import Timer

from bf16.common.ae_logging import (
    float_abs_error,
    resolve_seed,
    resolve_samples,
    should_dump_rows,
    write_case_csv,
)
from bf16.common.cmodel_ref import fp32_exp2_pwl
from bf16.common.cocotb_utils import bits_to_f32, rand_fp32_bits


@cocotb.test()
async def test_fp32_exp2_pwl_matches_cmodel(dut):
    seed = resolve_seed(20260312)
    samples = resolve_samples(2000)
    rng = random.Random(seed)
    mismatches = 0
    errs = []
    rows = []

    for _ in range(samples):
        x_bits = rand_fp32_bits(rng, -16.0, 4.0)
        dut.i_x_fp32.value = x_bits
        await Timer(1, units="ns")
        got = int(dut.o_y_fp32.value)
        exp = fp32_exp2_pwl(x_bits)
        if got != exp:
            mismatches += 1
        ae = float_abs_error(got, exp)
        errs.append(ae)
        if should_dump_rows():
            rows.append(
                {
                    "idx": len(rows),
                    "x_bits": f"0x{x_bits:08x}",
                    "rtl_bits": f"0x{got:08x}",
                    "cmodel_bits": f"0x{exp:08x}",
                    "rtl_f32": bits_to_f32(got),
                    "cmodel_f32": bits_to_f32(exp),
                    "ae": ae,
                }
            )

    mae = sum(errs) / len(errs)
    maxe = max(errs) if errs else 0.0
    if should_dump_rows():
        csv_path = write_case_csv("fa_fp32_exp2_pwl", seed, rows)
        dut._log.info("fp32_exp2_pwl: detail_csv=%s", csv_path)
    dut._log.info("fp32_exp2_pwl: seed=%d samples=%d mismatches=%d MAE=%.6f MaxAE=%.6f", seed, samples, mismatches, mae, maxe)
    assert mismatches == 0
