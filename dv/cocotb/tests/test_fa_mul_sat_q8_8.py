import random
import cocotb
from cocotb.triggers import Timer

from fp_ref import q8_8_mul_sat, to_s16


@cocotb.test()
async def test_mul_directed(dut):
    vectors = [
        (0, 0),
        (256, 256),
        (-256, 256),
        (32767, 32767),
        (-32768, 32767),
        (1024, -512),
    ]

    for a, b in vectors:
        dut.i_a_q8_8.value = a & 0xFFFF
        dut.i_b_q8_8.value = b & 0xFFFF
        await Timer(1, units="ns")
        got = to_s16(int(dut.o_y_q8_8.value))
        exp = q8_8_mul_sat(to_s16(a), to_s16(b))
        assert got == exp, f"directed mismatch a={a}, b={b}, got={got}, exp={exp}"


@cocotb.test()
async def test_mul_random(dut):
    random.seed(20260302)
    for _ in range(500):
        a = random.randint(-32768, 32767)
        b = random.randint(-32768, 32767)
        dut.i_a_q8_8.value = a & 0xFFFF
        dut.i_b_q8_8.value = b & 0xFFFF
        await Timer(1, units="ns")
        got = to_s16(int(dut.o_y_q8_8.value))
        exp = q8_8_mul_sat(a, b)
        assert got == exp, f"random mismatch a={a}, b={b}, got={got}, exp={exp}"
