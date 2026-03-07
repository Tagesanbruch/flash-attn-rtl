import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from fp_ref import exp_pwl_q1_15, exp_real_q1_15, q1_15_to_float


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.i_valid.value = 0
    dut.i_x_q8_8.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def pipeline_latency():
    exp_name = os.environ.get("EXP_NAME", "base")
    if exp_name == "base":
        return 1
    if exp_name == "exp_a":
        return 2
    return 3


async def drive_and_collect(dut, x):
    dut.i_valid.value = 1
    dut.i_x_q8_8.value = x & 0xFFFF
    await RisingEdge(dut.clk)
    dut.i_valid.value = 0
    dut.i_x_q8_8.value = 0

    for _ in range(pipeline_latency() + 2):
        await RisingEdge(dut.clk)
        if int(dut.o_valid.value) == 1:
            return int(dut.o_exp_q1_15.value) & 0xFFFF
    return None


@cocotb.test()
async def test_exp_directed(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    for x in [0, -256, -512, -1024, -2048, 128, -4096]:
        got = await drive_and_collect(dut, x)
        exp = exp_pwl_q1_15(x)
        assert got == exp, f"directed mismatch x={x}, got={got}, exp={exp}"


@cocotb.test()
async def test_exp_monotonic_and_error(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    last = None
    for x in range(0, -4097, -16):
        got = await drive_and_collect(dut, x)
        if last is not None:
            assert got <= last, f"monotonic violated at x={x}, got={got}, last={last}"
        last = got

    random.seed(20260308)
    for _ in range(400):
        x = random.randint(-3000, 400)
        got = await drive_and_collect(dut, x)
        real = exp_real_q1_15(x)
        err = abs(q1_15_to_float(got) - q1_15_to_float(real))
        assert err < 0.08, f"exp approx error too large x={x}, got={got}, real={real}, err={err}"


@cocotb.test()
async def test_exp_pipeline_throughput(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    random.seed(20260309)
    values = [random.randint(-4096, 0) for _ in range(32)]
    results = []

    for x in values:
        dut.i_valid.value = 1
        dut.i_x_q8_8.value = x & 0xFFFF
        await RisingEdge(dut.clk)
        if int(dut.o_valid.value) == 1:
            results.append(int(dut.o_exp_q1_15.value) & 0xFFFF)

    dut.i_valid.value = 0
    dut.i_x_q8_8.value = 0
    for _ in range(pipeline_latency() + 2):
        await RisingEdge(dut.clk)
        if int(dut.o_valid.value) == 1:
            results.append(int(dut.o_exp_q1_15.value) & 0xFFFF)

    assert len(results) == len(values), f"Expected {len(values)} results, got {len(results)}"
    for x, got in zip(values, results):
        exp = exp_pwl_q1_15(x)
        assert got == exp, f"throughput mismatch x={x}, got={got}, exp={exp}"
