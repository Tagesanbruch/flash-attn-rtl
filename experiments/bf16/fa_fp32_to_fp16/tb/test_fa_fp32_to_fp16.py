import random

import cocotb
from cocotb.triggers import Timer

from bf16.common.ae_logging import resolve_samples, resolve_seed
from bf16.common.golden_models import f32_to_bits, fp32_to_fp16_bits


@cocotb.test()
async def test_fp32_to_fp16_reference(dut):
    seed = resolve_seed(20260315)
    samples = resolve_samples(5000)
    rng = random.Random(seed)

    mismatches = 0
    vectors = [
        0x00000000,
        0x80000000,
        0x3F800000,
        0xBF800000,
        0x7F800000,
        0xFF800000,
        0x7FC00000,
        0x00800000,
        0x00000001,
    ]
    for _ in range(samples - len(vectors)):
        vectors.append(f32_to_bits(rng.uniform(-1000.0, 1000.0)))

    for x_bits in vectors:
        dut.i_x_fp32.value = x_bits
        await Timer(1, units="ns")
        got = int(dut.o_y_fp16.value) & 0xFFFF
        exp = fp32_to_fp16_bits(x_bits)
        if got != exp:
            mismatches += 1

    dut._log.info(
        "fp32_to_fp16: seed=%d samples=%d mismatches=%d",
        seed,
        samples,
        mismatches,
    )
    assert mismatches == 0
