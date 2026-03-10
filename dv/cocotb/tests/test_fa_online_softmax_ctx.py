import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


LATENCY = 5


def to_s16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def to_s32(v: int) -> int:
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v & 0x80000000 else v


def to_u32(v: int) -> int:
    return v & 0xFFFFFFFF


def exp2_ref_q1_15(x_q8_8: int) -> int:
    x_q8_8 = max(min(x_q8_8, 0), -4096)
    z_q8_8 = ((-x_q8_8) * 369 + 128) >> 8
    int_part = (z_q8_8 >> 8) & 0xFF
    frac_part = z_q8_8 & 0xFF
    table = [
        32768, 32066, 31379, 30706, 30048, 29405, 28774, 28158,
        27554, 26964, 26386, 25821, 25268, 24726, 24196, 23678,
        23170, 22674, 22188, 21713, 21247, 20792, 20347, 19911,
        19484, 19066, 18658, 18258, 17867, 17484, 17109, 16743,
    ]
    frac_val = table[frac_part >> 3]
    if int_part >= 16:
        return 0
    return (frac_val >> int_part) & 0xFFFF


def step_model(state, score, value):
    m_prev, l_prev, acc_prev = state
    m_new = score if score > m_prev else m_prev
    exp_old = exp2_ref_q1_15(m_prev - m_new)
    exp_new = exp2_ref_q1_15(score - m_new)
    l_scaled = (l_prev * exp_old) >> 15
    l_new = to_u32(l_scaled + (exp_new << 1))
    acc_scaled = (acc_prev * exp_old) >> 15
    v_term = (exp_new * value) >> 7
    acc_new = to_s32(acc_scaled + v_term)
    return (to_s16(m_new), l_new, acc_new)


@cocotb.test()
async def test_softmax_ctx_rtl_pipeline(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())

    dut.rst_n.value = 0
    dut.i_valid.value = 0
    dut.i_row_start.value = 0
    dut.i_row_end.value = 0
    dut.i_ctx_id.value = 0
    dut.i_init_m_q8_8.value = 0x8000
    dut.i_init_l_q16_16.value = 0
    dut.i_init_acc_q16_16.value = 0
    dut.i_score_q8_8.value = 0
    dut.i_value_q8_8.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    random.seed(20260310)
    ctx_order = [0, 1, 2, 3]
    ctx_states = {ctx: (-32768, 0, 0) for ctx in ctx_order}
    rows_left = {ctx: 2 for ctx in ctx_order}
    row_pos = {ctx: 0 for ctx in ctx_order}
    row_len = {ctx: random.randint(3, 6) for ctx in ctx_order}
    expected = []
    cycle = 0
    rr = 0

    while any(v > 0 for v in rows_left.values()):
        ctx = ctx_order[rr % len(ctx_order)]
        rr += 1
        if rows_left[ctx] == 0:
            dut.i_valid.value = 0
        else:
            pos = row_pos[ctx]
            score = random.randint(-1536, 1536)
            value = random.randint(-1024, 1023)
            row_start = pos == 0
            row_end = pos == row_len[ctx] - 1
            prev_state = (-32768, 0, 0) if row_start else ctx_states[ctx]
            new_state = step_model(prev_state, score, value)
            ctx_states[ctx] = new_state
            expected.append((cycle + LATENCY, ctx, row_end, new_state))

            dut.i_valid.value = 1
            dut.i_row_start.value = 1 if row_start else 0
            dut.i_row_end.value = 1 if row_end else 0
            dut.i_ctx_id.value = ctx
            dut.i_init_m_q8_8.value = 0x8000
            dut.i_init_l_q16_16.value = 0
            dut.i_init_acc_q16_16.value = 0
            dut.i_score_q8_8.value = score & 0xFFFF
            dut.i_value_q8_8.value = value & 0xFFFF

            row_pos[ctx] += 1
            if row_end:
                rows_left[ctx] -= 1
                row_pos[ctx] = 0
                row_len[ctx] = random.randint(3, 6)

        await RisingEdge(dut.clk)
        cycle += 1

        if int(dut.o_valid.value):
            due, ref_ctx, ref_done, ref_state = expected.pop(0)
            assert due <= cycle
            assert int(dut.o_ctx_id.value) == ref_ctx
            assert int(dut.o_row_done.value) == (1 if ref_done else 0)
            assert to_s16(int(dut.o_m_q8_8.value)) == ref_state[0]
            assert to_u32(int(dut.o_l_q16_16.value)) == ref_state[1]
            assert to_s32(int(dut.o_acc_q16_16.value)) == ref_state[2]

    dut.i_valid.value = 0
    for _ in range(LATENCY + 3):
        await RisingEdge(dut.clk)
        cycle += 1
        if int(dut.o_valid.value):
            due, ref_ctx, ref_done, ref_state = expected.pop(0)
            assert due <= cycle
            assert int(dut.o_ctx_id.value) == ref_ctx
            assert int(dut.o_row_done.value) == (1 if ref_done else 0)
            assert to_s16(int(dut.o_m_q8_8.value)) == ref_state[0]
            assert to_u32(int(dut.o_l_q16_16.value)) == ref_state[1]
            assert to_s32(int(dut.o_acc_q16_16.value)) == ref_state[2]

    assert not expected, f"undrained outputs: {len(expected)}"
