import random

import cocotb
from cocotb.triggers import Timer

from bf16.common.ae_logging import resolve_samples, resolve_seed
from bf16.common.golden_models import fp16_to_fp32_bits


def _is_fp32_nan(x_bits: int) -> bool:
    exp = (x_bits >> 23) & 0xFF
    frac = x_bits & 0x7FFFFF
    return exp == 0xFF and frac != 0


@cocotb.test()
async def test_fp16_to_fp32_reference(dut):
    seed = resolve_seed(20260315)
    samples = resolve_samples(5000)
    rng = random.Random(seed)

    mismatches = 0
    # Include deterministic corner cases first.
    vectors = [0x0000, 0x8000, 0x3C00, 0xBC00, 0x7C00, 0xFC00, 0x7E00, 0x0001, 0x03FF]
    vectors.extend(rng.randrange(0, 1 << 16) for _ in range(samples - len(vectors)))

    for x_bits in vectors:
        dut.i_x_fp16.value = x_bits
        await Timer(1, units="ns")
        got = int(dut.o_y_fp32.value) & 0xFFFFFFFF
        exp = fp16_to_fp32_bits(x_bits)
        if got != exp and not (_is_fp32_nan(got) and _is_fp32_nan(exp)):
            mismatches += 1

    dut._log.info(
        "fp16_to_fp32: seed=%d samples=%d mismatches=%d",
        seed,
        samples,
        mismatches,
    )
    assert mismatches == 0
