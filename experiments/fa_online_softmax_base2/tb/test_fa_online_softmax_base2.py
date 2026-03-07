import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from fp_ref import to_s16, to_s32, to_u32


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


@cocotb.test()
async def test_online_softmax_base2_row(dut):
    fine = os.environ.get("EXP_NAME", "base") == "exp_a"
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())

    dut.rst_n.value = 0
    dut.i_row_start.value = 0
    dut.i_valid.value = 0
    dut.i_row_end.value = 0
    dut.i_score_q8_8.value = 0
    dut.i_value_q8_8.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    random.seed(20260306)
    scores = [random.randint(-1536, 1536) for _ in range(24)]
    values = [random.randint(-2048, 2047) for _ in range(24)]

    m_ref = -32768
    l_ref = 0
    acc_ref = 0

    for idx, (score, value) in enumerate(zip(scores, values)):
        dut.i_row_start.value = 1 if idx == 0 else 0
        dut.i_valid.value = 1
        dut.i_row_end.value = 1 if idx == len(scores) - 1 else 0
        dut.i_score_q8_8.value = score & 0xFFFF
        dut.i_value_q8_8.value = value & 0xFFFF

        await RisingEdge(dut.clk)
        await Timer(1, units="ps")

        m_ref, l_ref, acc_ref = online_softmax_base2_step(m_ref, l_ref, acc_ref, score, value, fine)

        m_got = to_s16(int(dut.o_m_q8_8.value))
        l_got = to_u32(int(dut.o_l_q16_16.value))
        acc_got = to_s32(int(dut.o_acc_q16_16.value))

        assert m_got == m_ref, f"m mismatch idx={idx}, got={m_got}, ref={m_ref}"
        assert l_got == l_ref, f"l mismatch idx={idx}, got={l_got}, ref={l_ref}"
        assert acc_got == acc_ref, f"acc mismatch idx={idx}, got={acc_got}, ref={acc_ref}"

    assert int(dut.o_row_done.value) == 1, "row_done should pulse on last sample"


@cocotb.test()
async def test_online_softmax_base2_multi_rows(dut):
    fine = os.environ.get("EXP_NAME", "base") == "exp_a"
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())

    dut.rst_n.value = 0
    dut.i_row_start.value = 0
    dut.i_valid.value = 0
    dut.i_row_end.value = 0
    dut.i_score_q8_8.value = 0
    dut.i_value_q8_8.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    random.seed(20260307)
    for row_idx in range(4):
        row_len = random.randint(4, 20)
        m_ref = -32768
        l_ref = 0
        acc_ref = 0

        for idx in range(row_len):
            score = random.randint(-2048, 2048)
            value = random.randint(-2048, 2047)
            dut.i_row_start.value = 1 if idx == 0 else 0
            dut.i_valid.value = 1
            dut.i_row_end.value = 1 if idx == row_len - 1 else 0
            dut.i_score_q8_8.value = score & 0xFFFF
            dut.i_value_q8_8.value = value & 0xFFFF

            await RisingEdge(dut.clk)
            await Timer(1, units="ps")

            m_ref, l_ref, acc_ref = online_softmax_base2_step(m_ref, l_ref, acc_ref, score, value, fine)
            assert to_s16(int(dut.o_m_q8_8.value)) == m_ref, f"row {row_idx} m mismatch"
            assert to_u32(int(dut.o_l_q16_16.value)) == l_ref, f"row {row_idx} l mismatch"
            assert to_s32(int(dut.o_acc_q16_16.value)) == acc_ref, f"row {row_idx} acc mismatch"

        assert int(dut.o_row_done.value) == 1, f"row {row_idx} missing done pulse"
        dut.i_valid.value = 0
        dut.i_row_start.value = 0
        dut.i_row_end.value = 0
        await RisingEdge(dut.clk)
        await Timer(1, units="ps")
        assert int(dut.o_row_done.value) == 0, f"row {row_idx} done pulse width error"
