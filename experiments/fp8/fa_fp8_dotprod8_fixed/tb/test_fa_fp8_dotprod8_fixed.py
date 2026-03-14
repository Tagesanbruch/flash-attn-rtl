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

    return -mag if sign else mag


def pack_u8(vec):
    out = 0
    for i, v in enumerate(vec):
        out |= (v & 0xFF) << (i * 8)
    return out


@cocotb.test()
async def test_fp8_dotprod8_fixed_random(dut):
    rng = random.Random(20260315)
    samples = 3000
    mismatches = 0

    for _ in range(samples):
        a = [rng.randrange(0, 256) for _ in range(8)]
        b = [rng.randrange(0, 256) for _ in range(8)]

        dut.i_a_vec.value = pack_u8(a)
        dut.i_b_vec.value = pack_u8(b)
        await Timer(1, units="ns")

        got_u = int(dut.o_dot_q8_11.value) & 0xFFFFFFFF
        got = got_u if got_u < (1 << 31) else got_u - (1 << 32)

        acc_q8_22 = 0
        for x, y in zip(a, b):
            acc_q8_22 += fp8_e4m3_to_q4_11_ref(x) * fp8_e4m3_to_q4_11_ref(y)
        exp = acc_q8_22 >> 11

        if got != exp:
            mismatches += 1

    dut._log.info("fp8_dotprod8_fixed: samples=%d mismatches=%d", samples, mismatches)
    assert mismatches == 0
