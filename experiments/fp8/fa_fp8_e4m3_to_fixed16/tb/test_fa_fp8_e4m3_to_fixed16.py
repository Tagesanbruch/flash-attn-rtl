import random

import cocotb
from cocotb.triggers import Timer


def fp8_e4m3_to_q4_11_ref(x: int) -> int:
    sign = (x >> 7) & 1
    exp = (x >> 3) & 0xF
    frac = x & 0x7

    if exp == 0:
      mag = frac << 2
    elif exp == 0xF:
      mag = 32767
    else:
      mag = (8 + frac) << (exp + 1)
      mag = min(mag, 32767)

    val = -mag if sign else mag
    if val < -32768:
        val = -32768
    return val


@cocotb.test()
async def test_fp8_e4m3_to_fixed16_random(dut):
    rng = random.Random(20260315)
    samples = 5000
    mismatches = 0

    vectors = [0x00, 0x80, 0x38, 0xB8, 0x01, 0x7F, 0xFF]
    vectors.extend(rng.randrange(0, 256) for _ in range(samples - len(vectors)))

    for x in vectors:
        dut.i_fp8.value = x
        await Timer(1, units="ns")
        got_u = int(dut.o_q4_11.value) & 0xFFFF
        got = got_u if got_u < (1 << 15) else got_u - (1 << 16)
        exp = fp8_e4m3_to_q4_11_ref(x)
        if got != exp:
            mismatches += 1

    dut._log.info("fp8_e4m3_to_fixed16: samples=%d mismatches=%d", samples, mismatches)
    assert mismatches == 0
