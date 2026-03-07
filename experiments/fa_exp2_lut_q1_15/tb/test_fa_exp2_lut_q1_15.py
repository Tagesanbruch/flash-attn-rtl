import math
import os
import random

import cocotb
from cocotb.triggers import Timer


def exp2_ref_q1_15(x_q8_8: int, fine: bool) -> int:
    x_q8_8 = max(min(x_q8_8, 0), -4096)
    z_q8_8 = ((-x_q8_8) * 369 + 128) >> 8
    int_part = (z_q8_8 >> 8) & 0xFF
    frac_part = z_q8_8 & 0xFF

    if fine:
        table = [
            32768, 32066, 31379, 30706, 30048, 29405, 28774, 28158,
            27554, 26964, 26386, 25821, 25268, 24726, 24196, 23678,
            23170, 22674, 22188, 21713, 21247, 20792, 20347, 19911,
            19484, 19066, 18658, 18258, 17867, 17484, 17109, 16743,
        ]
        frac_val = table[frac_part >> 3]
    else:
        table = [
            32768, 31379, 30048, 28774, 27554, 26386, 25268, 24196,
            23170, 22188, 21247, 20347, 19484, 18658, 17867, 17109,
        ]
        frac_val = table[frac_part >> 4]

    if int_part >= 16:
        return 0
    return (frac_val >> int_part) & 0xFFFF


def q1_15_to_float(x: int) -> float:
    return (x & 0xFFFF) / 32768.0


@cocotb.test()
async def test_exp2_directed(dut):
    fine = os.environ.get("EXP_NAME", "base") == "exp_a"
    directed = [0, -64, -256, -512, -1024, -2048, -3072, -4096, 128]

    for x in directed:
        dut.i_x_q8_8.value = x & 0xFFFF
        await Timer(1, units="ns")
        got = int(dut.o_exp_q1_15.value) & 0xFFFF
        ref = exp2_ref_q1_15(x, fine)
        assert got == ref, f"directed mismatch x={x}, got={got}, ref={ref}"


@cocotb.test()
async def test_exp2_monotonic_and_error(dut):
    fine = os.environ.get("EXP_NAME", "base") == "exp_a"
    random.seed(20260306)

    last = None
    for x in range(0, -4097, -8):
        dut.i_x_q8_8.value = x & 0xFFFF
        await Timer(1, units="ns")
        got = int(dut.o_exp_q1_15.value) & 0xFFFF
        if last is not None:
            assert got <= last, f"monotonic violated x={x}, got={got}, last={last}"
        last = got

    max_err = 0.0
    limit = 0.06 if fine else 0.09
    for _ in range(400):
        x = random.randint(-4096, 256)
        dut.i_x_q8_8.value = x & 0xFFFF
        await Timer(1, units="ns")
        got = int(dut.o_exp_q1_15.value) & 0xFFFF
        real = math.exp(max(min(x / 256.0, 0.0), -16.0))
        err = abs(q1_15_to_float(got) - real)
        max_err = max(max_err, err)

    assert max_err < limit, f"max err too large: got {max_err}, limit {limit}"
