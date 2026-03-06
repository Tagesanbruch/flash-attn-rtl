import random
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from fp_ref import online_softmax_step, recip_q16_16, to_s16, to_s32, to_u32


def row_reduction_ref(scores, values):
    m_reg = -32768
    l_reg = 0
    acc_reg = 0

    for s, v in zip(scores, values):
        m_reg, l_reg, acc_reg = online_softmax_step(m_reg, l_reg, acc_reg, s, v)

    recip = recip_q16_16(l_reg)

    norm_full = to_s32(acc_reg) * recip
    norm_shifted = norm_full >> 16
    result = norm_shifted & 0xFFFFFFFF
    result_s32 = to_s32(result)

    if result_s32 > 32767:
        return 32767
    elif result_s32 < -32768:
        return -32768
    else:
        return to_s16(result_s32)


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.i_row_start.value = 0
    dut.i_valid.value = 0
    dut.i_row_end.value = 0
    dut.i_score_q8_8.value = 0
    dut.i_value_q8_8.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def drive_row(dut, scores, values, wait_cycles=20):
    for i, (s, v) in enumerate(zip(scores, values)):
        dut.i_valid.value = 1
        dut.i_score_q8_8.value = s & 0xFFFF
        dut.i_value_q8_8.value = v & 0xFFFF
        dut.i_row_start.value = 1 if i == 0 else 0
        dut.i_row_end.value = 1 if i == len(scores) - 1 else 0
        await RisingEdge(dut.clk)

    dut.i_valid.value = 0
    dut.i_row_start.value = 0
    dut.i_row_end.value = 0
    dut.i_score_q8_8.value = 0
    dut.i_value_q8_8.value = 0

    for _ in range(wait_cycles):
        await RisingEdge(dut.clk)
        if int(dut.o_row_out_valid.value) == 1:
            raw = int(dut.o_row_out_q8_8.value)
            return to_s16(raw)
    return None


@cocotb.test()
async def test_row_reduction_simple(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    exp_name = os.environ.get("EXP_NAME", "base")
    tol = 0 if exp_name == "base" else 3

    scores = [256, 512, 128, 384]
    values = [100, 200, 300, 400]

    ref = row_reduction_ref(scores, values)
    got = await drive_row(dut, scores, values)

    assert got is not None, "No o_row_out_valid after driving row"
    diff = abs(got - ref)
    assert diff <= tol, f"simple row mismatch: got={got}, ref={ref}, diff={diff}, tol={tol}"


@cocotb.test()
async def test_row_reduction_multi_rows(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    exp_name = os.environ.get("EXP_NAME", "base")
    tol = 0 if exp_name == "base" else 3

    random.seed(20260306)

    for row_idx in range(5):
        row_len = random.randint(4, 16)
        scores = [random.randint(-2048, 2048) for _ in range(row_len)]
        values = [random.randint(-2048, 2048) for _ in range(row_len)]

        ref = row_reduction_ref(scores, values)
        got = await drive_row(dut, scores, values, wait_cycles=30)

        assert got is not None, f"Row {row_idx}: No o_row_out_valid"
        diff = abs(got - ref)
        assert diff <= tol, \
            f"Row {row_idx}: got={got}, ref={ref}, diff={diff}, tol={tol}"

        await ClockCycles(dut.clk, 5)


@cocotb.test()
async def test_row_reduction_edge_cases(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    exp_name = os.environ.get("EXP_NAME", "base")
    tol = 0 if exp_name == "base" else 3

    scores = [0, 0, 0, 0]
    values = [256, 256, 256, 256]
    ref = row_reduction_ref(scores, values)
    got = await drive_row(dut, scores, values)
    assert got is not None, "Edge case 1: No valid"
    diff = abs(got - ref)
    assert diff <= tol, f"Edge case 1 (equal scores): got={got}, ref={ref}, diff={diff}"

    await ClockCycles(dut.clk, 5)

    scores = [1000]
    values = [500]
    ref = row_reduction_ref(scores, values)
    got = await drive_row(dut, scores, values)
    assert got is not None, "Edge case 2: No valid"
    diff = abs(got - ref)
    assert diff <= tol, f"Edge case 2 (single element): got={got}, ref={ref}, diff={diff}"
