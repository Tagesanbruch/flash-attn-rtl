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
from bf16.common.cmodel_ref import bf16_to_fp32
from bf16.common.cocotb_utils import bits_to_f32


@cocotb.test()
async def test_bf16_to_fp32_matches_cmodel(dut):
    seed = resolve_seed(20260312)
    samples = resolve_samples(2000)
    rng = random.Random(seed)
    mismatches = 0
    errs = []
    rows = []

    for _ in range(samples):
        x_bits = rng.randrange(0, 1 << 16)
        dut.i_x_bf16.value = x_bits
        await Timer(1, units="ns")
        got = int(dut.o_y_fp32.value)
        exp = bf16_to_fp32(x_bits)
        if got != exp:
            mismatches += 1
        ae = float_abs_error(got, exp)
        errs.append(ae)
        if should_dump_rows():
            rows.append(
                {
                    "idx": len(rows),
                    "x_bf16": f"0x{x_bits:04x}",
                    "rtl_bits": f"0x{got:08x}",
                    "cmodel_bits": f"0x{exp:08x}",
                    "rtl_f32": bits_to_f32(got),
                    "cmodel_f32": bits_to_f32(exp),
                    "ae": ae,
                }
            )

    mae = sum(errs) / len(errs) if errs else 0.0
    maxe = max(errs) if errs else 0.0
    if should_dump_rows():
        csv_path = write_case_csv("fa_bf16_to_fp32", seed, rows)
        dut._log.info("bf16_to_fp32: detail_csv=%s", csv_path)
    dut._log.info("bf16_to_fp32: seed=%d samples=%d mismatches=%d MAE=%.6f MaxAE=%.6f", seed, samples, mismatches, mae, maxe)
    assert mismatches == 0
