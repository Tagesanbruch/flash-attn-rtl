import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from fp_ref import recip_q16_16


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.i_valid.value = 0
    dut.i_x_q16_16.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def drive_and_collect(dut, x_val, pipeline_depth=15):
    dut.i_valid.value = 1
    dut.i_x_q16_16.value = x_val & 0xFFFFFFFF
    await RisingEdge(dut.clk)
    dut.i_valid.value = 0
    dut.i_x_q16_16.value = 0

    for _ in range(pipeline_depth + 1):
        await RisingEdge(dut.clk)
        if int(dut.o_valid.value) == 1:
            return int(dut.o_recip_q16_16.value) & 0xFFFFFFFF
    return None


def within_tolerance(got, exp, tol=0):
    if exp == 0xFFFFFFFF:
        return got == exp
    diff = abs(int(got) - int(exp))
    return diff <= tol


@cocotb.test()
async def test_recip_directed(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    import os
    exp_name = os.environ.get("EXP_NAME", "base")
    tol = 0 if exp_name == "base" else 2

    vectors = [
        0,
        1 << 16,
        2 << 16,
        3 << 16,
        (1 << 16) // 2,
        0x00010000,
        0x7FFFFFFF,
        1,
        0x00000100,
        0x00008000,
        0x00100000,
        0x80000000,
        0xFFFFFFFF,
    ]

    for x in vectors:
        got = await drive_and_collect(dut, x)
        assert got is not None, f"No o_valid for x={x}"
        exp = recip_q16_16(x)
        assert within_tolerance(got, exp, tol), \
            f"directed mismatch x={hex(x)}, got={hex(got)}, exp={hex(exp)}, tol={tol}"


@cocotb.test()
async def test_recip_random(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    import os
    exp_name = os.environ.get("EXP_NAME", "base")
    tol = 0 if exp_name == "base" else 2

    random.seed(20260306)
    for _ in range(500):
        x = random.randint(1, 0xFFFFFFFF)
        got = await drive_and_collect(dut, x)
        assert got is not None, f"No o_valid for x={x}"
        exp = recip_q16_16(x)
        assert within_tolerance(got, exp, tol), \
            f"random mismatch x={hex(x)}, got={hex(got)}, exp={hex(exp)}, tol={tol}"


@cocotb.test()
async def test_recip_pipeline_throughput(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    import os
    exp_name = os.environ.get("EXP_NAME", "base")
    tol = 0 if exp_name == "base" else 2

    random.seed(20260307)
    test_values = [random.randint(1, 0xFFFFFFFF) for _ in range(20)]

    results = []
    for x in test_values:
        dut.i_valid.value = 1
        dut.i_x_q16_16.value = x & 0xFFFFFFFF
        await RisingEdge(dut.clk)
        if int(dut.o_valid.value) == 1:
            results.append(int(dut.o_recip_q16_16.value) & 0xFFFFFFFF)
    dut.i_valid.value = 0
    dut.i_x_q16_16.value = 0

    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.o_valid.value) == 1:
            results.append(int(dut.o_recip_q16_16.value) & 0xFFFFFFFF)

    assert len(results) == len(test_values), \
        f"Expected {len(test_values)} results, got {len(results)}"

    for i, (x, got) in enumerate(zip(test_values, results)):
        exp = recip_q16_16(x)
        assert within_tolerance(got, exp, tol), \
            f"pipeline mismatch [{i}] x={hex(x)}, got={hex(got)}, exp={hex(exp)}"
