import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from fp_ref import q8_8_mul_sat, to_s16


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.i_valid.value = 0
    dut.i_a_q8_8.value = 0
    dut.i_b_q8_8.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def pipeline_latency():
    return 1 if os.environ.get("EXP_NAME", "base") == "base" else 2


async def drive_and_collect(dut, a, b):
    dut.i_valid.value = 1
    dut.i_a_q8_8.value = a & 0xFFFF
    dut.i_b_q8_8.value = b & 0xFFFF
    await RisingEdge(dut.clk)
    dut.i_valid.value = 0
    dut.i_a_q8_8.value = 0
    dut.i_b_q8_8.value = 0

    for _ in range(pipeline_latency() + 2):
        await RisingEdge(dut.clk)
        if int(dut.o_valid.value) == 1:
            return to_s16(int(dut.o_y_q8_8.value))
    return None


@cocotb.test()
async def test_mul_directed(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    vectors = [
        (0, 0),
        (256, 256),
        (-256, 256),
        (32767, 32767),
        (-32768, 32767),
        (1024, -512),
    ]

    for a, b in vectors:
        got = await drive_and_collect(dut, a, b)
        exp = q8_8_mul_sat(to_s16(a), to_s16(b))
        assert got == exp, f"directed mismatch a={a}, b={b}, got={got}, exp={exp}"


@cocotb.test()
async def test_mul_random(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    random.seed(20260306)
    for _ in range(500):
        a = random.randint(-32768, 32767)
        b = random.randint(-32768, 32767)
        got = await drive_and_collect(dut, a, b)
        exp = q8_8_mul_sat(a, b)
        assert got == exp, f"random mismatch a={a}, b={b}, got={got}, exp={exp}"


@cocotb.test()
async def test_mul_pipeline_throughput(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    random.seed(20260307)
    vectors = [(random.randint(-32768, 32767), random.randint(-32768, 32767)) for _ in range(32)]

    results = []
    for a, b in vectors:
        dut.i_valid.value = 1
        dut.i_a_q8_8.value = a & 0xFFFF
        dut.i_b_q8_8.value = b & 0xFFFF
        await RisingEdge(dut.clk)
        if int(dut.o_valid.value) == 1:
            results.append(to_s16(int(dut.o_y_q8_8.value)))

    dut.i_valid.value = 0
    dut.i_a_q8_8.value = 0
    dut.i_b_q8_8.value = 0

    for _ in range(pipeline_latency() + 2):
        await RisingEdge(dut.clk)
        if int(dut.o_valid.value) == 1:
            results.append(to_s16(int(dut.o_y_q8_8.value)))

    assert len(results) == len(vectors), f"Expected {len(vectors)} results, got {len(results)}"
    for (a, b), got in zip(vectors, results):
        exp = q8_8_mul_sat(a, b)
        assert got == exp, f"throughput mismatch a={a}, b={b}, got={got}, exp={exp}"
