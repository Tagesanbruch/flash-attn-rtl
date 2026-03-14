import random

import cocotb
from cocotb.triggers import Timer


def pack_i8(vec):
    out = 0
    for i, v in enumerate(vec):
        out |= (v & 0xFF) << (i * 8)
    return out


@cocotb.test()
async def test_int8_dotprod16_random(dut):
    rng = random.Random(20260315)
    mismatches = 0
    samples = 4000

    for _ in range(samples):
        a = [rng.randint(-128, 127) for _ in range(16)]
        b = [rng.randint(-128, 127) for _ in range(16)]
        dut.i_a_vec.value = pack_i8(a)
        dut.i_b_vec.value = pack_i8(b)
        await Timer(1, units="ns")

        got_u = int(dut.o_dot.value) & 0xFFFFFFFF
        got = got_u if got_u < (1 << 31) else got_u - (1 << 32)
        exp = sum(x * y for x, y in zip(a, b))
        if got != exp:
            mismatches += 1

    dut._log.info("int8_dotprod16: samples=%d mismatches=%d", samples, mismatches)
    assert mismatches == 0
