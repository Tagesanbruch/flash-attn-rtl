import random
import cocotb
from cocotb.triggers import Timer

from fp_ref import exp_pwl_q1_15, exp_real_q1_15, q1_15_to_float


@cocotb.test()
async def test_exp_directed(dut):
    directed = [0, -256, -512, -1024, -2048, 128, -4096]
    for x in directed:
        dut.i_x_q8_8.value = x & 0xFFFF
        await Timer(1, units="ns")
        got = int(dut.o_exp_q1_15.value) & 0xFFFF
        exp = exp_pwl_q1_15(x)
        assert got == exp, f"directed mismatch x={x}, got={got}, exp={exp}"


@cocotb.test()
async def test_exp_monotonic_and_error(dut):
    random.seed(20260302)
    last = None
    for x in range(0, -4097, -16):
        dut.i_x_q8_8.value = x & 0xFFFF
        await Timer(1, units="ns")
        got = int(dut.o_exp_q1_15.value) & 0xFFFF
        if last is not None:
            assert got <= last, f"monotonic violated at x={x}, got={got}, last={last}"
        last = got

    for _ in range(400):
        x = random.randint(-3000, 400)
        dut.i_x_q8_8.value = x & 0xFFFF
        await Timer(1, units="ns")
        got = int(dut.o_exp_q1_15.value) & 0xFFFF
        real = exp_real_q1_15(x)
        err = abs(q1_15_to_float(got) - q1_15_to_float(real))
        assert err < 0.08, f"exp approx error too large x={x}, got={got}, real={real}, err={err}"
