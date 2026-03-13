import random

import cocotb
from cocotb.triggers import Timer

from bf16.common.ae_logging import (
    resolve_seed,
    resolve_samples,
    should_dump_rows,
    write_case_csv,
)
from bf16.common.cmodel_ref import fp32_to_bf16
from bf16.common.cocotb_utils import rand_fp32_bits, bits_to_f32


def bf16_to_float(bf16_bits):
    """Convert BF16 bits to equivalent float value.""" 
    fp32_bits = (bf16_bits & 0xFFFF) << 16
    return bits_to_f32(fp32_bits)


@cocotb.test()
async def test_fp32_to_bf16_matches_cmodel(dut):
    seed = resolve_seed(20260312)
    samples = resolve_samples(2000)
    rng = random.Random(seed)
    mismatches = 0
    errs_rtl_vs_cmodel = []
    errs_quant = []
    rows = []

    for _ in range(samples):
        x_bits = rand_fp32_bits(rng, -16.0, 16.0)
        dut.i_x_fp32.value = x_bits
        await Timer(1, units="ns")
        got = int(dut.o_y_bf16.value)
        exp = fp32_to_bf16(x_bits)
        if got != exp:
            mismatches += 1
        # RTL vs cmodel error (in reconstructed FP32 domain)
        got_fp32_bits = (got & 0xFFFF) << 16
        exp_fp32_bits = (exp & 0xFFFF) << 16
        errs_rtl_vs_cmodel.append(abs(bits_to_f32(got_fp32_bits) - bits_to_f32(exp_fp32_bits)))

        # FP32 -> BF16 quantization error
        input_float = bits_to_f32(x_bits)
        output_float = bf16_to_float(got)
        quant_ae = abs(input_float - output_float)
        errs_quant.append(quant_ae)

        if should_dump_rows():
            rows.append(
                {
                    "idx": len(rows),
                    "x_bits": f"0x{x_bits:08x}",
                    "rtl_bf16": f"0x{got:04x}",
                    "cmodel_bf16": f"0x{exp:04x}",
                    "rtl_fp32_recon": bits_to_f32(got_fp32_bits),
                    "cmodel_fp32_recon": bits_to_f32(exp_fp32_bits),
                    "input_fp32": input_float,
                    "ae_rtl_vs_cmodel": errs_rtl_vs_cmodel[-1],
                    "ae_quant_input_vs_rtl": quant_ae,
                }
            )

    mae_rtl = sum(errs_rtl_vs_cmodel) / len(errs_rtl_vs_cmodel) if errs_rtl_vs_cmodel else 0.0
    maxe_rtl = max(errs_rtl_vs_cmodel) if errs_rtl_vs_cmodel else 0.0
    mae_quant = sum(errs_quant) / len(errs_quant) if errs_quant else 0.0
    maxe_quant = max(errs_quant) if errs_quant else 0.0
    if should_dump_rows():
        csv_path = write_case_csv("fa_fp32_to_bf16", seed, rows)
        dut._log.info("fp32_to_bf16: detail_csv=%s", csv_path)
    dut._log.info(
        "fp32_to_bf16: seed=%d samples=%d mismatches=%d MAE=%.6f MaxAE=%.6f MAE_quant=%.6f MaxAE_quant=%.6f",
        seed,
        samples,
        mismatches,
        mae_rtl,
        maxe_rtl,
        mae_quant,
        maxe_quant,
    )
    assert mismatches == 0
