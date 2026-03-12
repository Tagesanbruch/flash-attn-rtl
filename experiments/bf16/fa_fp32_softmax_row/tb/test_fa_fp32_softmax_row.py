import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from bf16.common.golden_models import bits_to_f32
from bf16.common.golden_models import online_softmax_fp32_step


def approx_equal_bits(got_bits: int, ref_bits: int, rel_tol: float = 0.12, abs_tol: float = 5e-3) -> None:
    got = bits_to_f32(got_bits)
    ref = bits_to_f32(ref_bits)
    err = abs(got - ref)
    limit = max(abs_tol, abs(ref) * rel_tol)
    assert err <= limit, (
        f"got={got} ref={ref} err={err} limit={limit} "
        f"got_bits=0x{got_bits:08x} ref_bits=0x{ref_bits:08x}"
    )


def random_bf16_in_range(low: float, high: float) -> int:
    from bf16.common.golden_models import f32_to_bits

    value = random.uniform(low, high)
    return (f32_to_bits(value) >> 16) & 0xFFFF


@cocotb.test()
async def test_fp32_softmax_row_multi_rows(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())

    dut.rst_n.value = 0
    dut.i_valid.value = 0
    dut.i_row_start.value = 0
    dut.i_row_end.value = 0
    dut.i_score_bf16.value = 0
    dut.i_value_bf16.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    random.seed(20260312)
    rows = []
    for _ in range(10):
        row_len = random.randint(2, 8)
        row = []
        for _ in range(row_len):
            row.append((random_bf16_in_range(-8.0, 8.0), random_bf16_in_range(-4.0, 4.0)))
        rows.append(row)

    expected = []
    m_old = 0
    l_old = 0
    acc_old = 0

    for row in rows:
        for idx, (score_bf16, value_bf16) in enumerate(row):
            row_start = idx == 0
            row_end = idx == len(row) - 1
            ref = online_softmax_fp32_step(m_old, l_old, acc_old, score_bf16, value_bf16, row_start)
            expected.append((row_end, ref))
            m_old = ref["m_new_bits"]
            l_old = ref["l_new_bits"]
            acc_old = ref["acc_new_bits"]

            dut.i_valid.value = 1
            dut.i_row_start.value = 1 if row_start else 0
            dut.i_row_end.value = 1 if row_end else 0
            dut.i_score_bf16.value = score_bf16
            dut.i_value_bf16.value = value_bf16

            await RisingEdge(dut.clk)
            await Timer(1, units="ps")
            assert int(dut.o_valid.value) == 1
            exp_row_done, exp_ref = expected.pop(0)
            assert int(dut.o_row_done.value) == (1 if exp_row_done else 0)
            assert int(dut.o_m_fp32.value) == exp_ref["m_new_bits"]
            approx_equal_bits(int(dut.o_exp_old_fp32.value) & 0xFFFFFFFF, exp_ref["exp_old_bits"], rel_tol=0.05, abs_tol=1e-3)
            approx_equal_bits(int(dut.o_exp_new_fp32.value) & 0xFFFFFFFF, exp_ref["exp_new_bits"], rel_tol=0.05, abs_tol=1e-3)
            approx_equal_bits(int(dut.o_l_fp32.value) & 0xFFFFFFFF, exp_ref["l_new_bits"], rel_tol=0.08, abs_tol=4e-3)
            approx_equal_bits(int(dut.o_acc_fp32.value) & 0xFFFFFFFF, exp_ref["acc_new_bits"], rel_tol=0.12, abs_tol=4e-3)

        m_old = 0
        l_old = 0
        acc_old = 0

    dut.i_valid.value = 0
    dut.i_row_start.value = 0
    dut.i_row_end.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, units="ps")
    assert int(dut.o_valid.value) == 0


@cocotb.test()
async def test_fp32_softmax_row_idle_hold(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())

    dut.rst_n.value = 0
    dut.i_valid.value = 0
    dut.i_row_start.value = 0
    dut.i_row_end.value = 0
    dut.i_score_bf16.value = 0
    dut.i_value_bf16.value = 0
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    dut.i_valid.value = 1
    dut.i_row_start.value = 1
    dut.i_row_end.value = 0
    dut.i_score_bf16.value = 0x3F80
    dut.i_value_bf16.value = 0x4000
    await RisingEdge(dut.clk)
    await Timer(1, units="ps")
    m_first = int(dut.o_m_fp32.value) & 0xFFFFFFFF
    l_first = int(dut.o_l_fp32.value) & 0xFFFFFFFF
    acc_first = int(dut.o_acc_fp32.value) & 0xFFFFFFFF

    dut.i_valid.value = 0
    dut.i_row_start.value = 0
    dut.i_row_end.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, units="ps")
    assert int(dut.o_valid.value) == 0
    assert (int(dut.o_m_fp32.value) & 0xFFFFFFFF) == m_first
    assert (int(dut.o_l_fp32.value) & 0xFFFFFFFF) == l_first
    assert (int(dut.o_acc_fp32.value) & 0xFFFFFFFF) == acc_first
