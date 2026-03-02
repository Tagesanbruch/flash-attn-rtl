import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from fp_ref import online_softmax_step, to_s16, to_s32, to_u32


@cocotb.test()
async def test_online_softmax_row(dut):
    clock = Clock(dut.clk, 2, units="ns")
    cocotb.start_soon(clock.start())

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

    random.seed(20260302)
    n = 32
    scores = [random.randint(-1024, 1024) for _ in range(n)]
    values = [random.randint(-2048, 2047) for _ in range(n)]

    m_ref = -32768
    l_ref = 0
    acc_ref = 0

    for idx, (s, v) in enumerate(zip(scores, values)):
        dut.i_row_start.value = 1 if idx == 0 else 0
        dut.i_valid.value = 1
        dut.i_row_end.value = 1 if idx == (n - 1) else 0
        dut.i_score_q8_8.value = s & 0xFFFF
        dut.i_value_q8_8.value = v & 0xFFFF

        await RisingEdge(dut.clk)
        await Timer(1, units="ps")

        m_ref, l_ref, acc_ref = online_softmax_step(m_ref, l_ref, acc_ref, s, v)

        m_got = to_s16(int(dut.o_m_q8_8.value))
        l_got = to_u32(int(dut.o_l_q16_16.value))
        acc_got = to_s32(int(dut.o_acc_q16_16.value))

        assert m_got == m_ref, f"m mismatch idx={idx}, got={m_got}, exp={m_ref}"
        assert l_got == l_ref, f"l mismatch idx={idx}, got={l_got}, exp={l_ref}"
        assert acc_got == acc_ref, f"acc mismatch idx={idx}, got={acc_got}, exp={acc_ref}"

    assert int(dut.o_row_done.value) == 1, "row_done should pulse at last valid cycle"

    dut.i_valid.value = 0
    dut.i_row_end.value = 0
    dut.i_row_start.value = 0

    await RisingEdge(dut.clk)
    await Timer(1, units="ps")
    assert int(dut.o_row_done.value) == 0, "row_done pulse width should be one cycle"
