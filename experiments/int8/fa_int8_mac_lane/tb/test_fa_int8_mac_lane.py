import random

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def test_int8_mac_lane_random(dut):
    rng = random.Random(20260315)
    mismatches = 0
    samples = 5000

    for _ in range(samples):
        a = rng.randint(-128, 127)
        b = rng.randint(-128, 127)
        acc = rng.randint(-(1 << 30), (1 << 30) - 1)

        dut.i_a.value = a & 0xFF
        dut.i_b.value = b & 0xFF
        dut.i_acc_in.value = acc & 0xFFFFFFFF
        await Timer(1, units="ns")

        got_u = int(dut.o_acc_out.value) & 0xFFFFFFFF
        got = got_u if got_u < (1 << 31) else got_u - (1 << 32)
        exp = acc + a * b
        if exp >= (1 << 31):
            exp -= 1 << 32
        if exp < -(1 << 31):
            exp += 1 << 32

        if got != exp:
            mismatches += 1

    dut._log.info("int8_mac_lane: samples=%d mismatches=%d", samples, mismatches)
    assert mismatches == 0
