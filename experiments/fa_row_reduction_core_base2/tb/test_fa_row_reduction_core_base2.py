import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from fp_ref import recip_q16_16, to_s16, to_s32, to_u32


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


def online_softmax_base2_step(m_reg: int, l_reg_u32: int, acc_reg: int, score: int, value: int, fine: bool):
    m_new = score if score > m_reg else m_reg
    diff_old = m_reg - m_new
    diff_new = score - m_new

    exp_old = exp2_ref_q1_15(diff_old, fine)
    exp_new = exp2_ref_q1_15(diff_new, fine)

    l_scaled = (l_reg_u32 * exp_old) >> 15
    l_term = (exp_new << 1) & 0xFFFFFFFF
    l_new = (l_scaled + l_term) & 0xFFFFFFFF

    acc_scaled = (acc_reg * exp_old) >> 15
    v_term = (exp_new * value) >> 7
    acc_new = to_s32(acc_scaled + v_term)

    return to_s16(m_new), to_u32(l_new), to_s32(acc_new)


def row_reduction_ref(scores, values, fine: bool):
    m_reg = -32768
    l_reg = 0
    acc_reg = 0

    for score, value in zip(scores, values):
        m_reg, l_reg, acc_reg = online_softmax_base2_step(m_reg, l_reg, acc_reg, score, value, fine)

    recip = recip_q16_16(l_reg)
    norm_full = to_s32(acc_reg) * recip
    norm_shifted = norm_full >> 16
    result_s32 = to_s32(norm_shifted)

    if result_s32 > 32767:
        return 32767
    if result_s32 < -32768:
        return -32768
    return to_s16(result_s32)


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.i_row_start.value = 0
    dut.i_valid.value = 0
    dut.i_row_end.value = 0
    dut.i_score_q8_8.value = 0
    dut.i_value_q8_8.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def drive_row(dut, scores, values, wait_cycles=8):
    for idx, (score, value) in enumerate(zip(scores, values)):
        dut.i_valid.value = 1
        dut.i_row_start.value = 1 if idx == 0 else 0
        dut.i_row_end.value = 1 if idx == len(scores) - 1 else 0
        dut.i_score_q8_8.value = score & 0xFFFF
        dut.i_value_q8_8.value = value & 0xFFFF
        await RisingEdge(dut.clk)

    dut.i_valid.value = 0
    dut.i_row_start.value = 0
    dut.i_row_end.value = 0
    dut.i_score_q8_8.value = 0
    dut.i_value_q8_8.value = 0

    for _ in range(wait_cycles):
        await RisingEdge(dut.clk)
        if int(dut.o_row_out_valid.value) == 1:
            return to_s16(int(dut.o_row_out_q8_8.value))
    return None


@cocotb.test()
async def test_row_reduction_base2_directed(dut):
    fine = os.environ.get("EXP_NAME", "base") == "exp_a"
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    scores = [256, 512, 128, 384]
    values = [100, 200, 300, 400]
    ref = row_reduction_ref(scores, values, fine)
    got = await drive_row(dut, scores, values)
    assert got is not None, "No output valid for directed row"
    assert got == ref, f"directed mismatch got={got}, ref={ref}"


@cocotb.test()
async def test_row_reduction_base2_random(dut):
    fine = os.environ.get("EXP_NAME", "base") == "exp_a"
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    random.seed(20260308)
    for row_idx in range(6):
        row_len = random.randint(4, 20)
        scores = [random.randint(-2048, 2048) for _ in range(row_len)]
        values = [random.randint(-2048, 2047) for _ in range(row_len)]
        ref = row_reduction_ref(scores, values, fine)
        got = await drive_row(dut, scores, values, wait_cycles=10)
        assert got is not None, f"row {row_idx} missing output"
        assert got == ref, f"row {row_idx} mismatch got={got}, ref={ref}"
        await ClockCycles(dut.clk, 3)
