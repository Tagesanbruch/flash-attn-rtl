import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


def latency() -> int:
    exp = os.environ.get("EXP_NAME", "base")
    return {
        "base": 1,
        "exp_a": 2,
        "exp_b": 3,
        "exp_c": 2,
        "exp_d": 3,
        "exp_e": 4,
        "exp_f": 6,
        "exp_g": 7,
        "exp_h": 8,
    }[exp]


def to_signed(value: int, bits: int) -> int:
    mask = (1 << bits) - 1
    value &= mask
    if value & (1 << (bits - 1)):
      return value - (1 << bits)
    return value


def pack_lanes(values):
    out = 0
    for idx, val in enumerate(values):
        out |= (val & 0xFFFF) << (idx * 16)
    return out


def ref_dot(q, k):
    total = 0
    for a, b in zip(q, k):
        total += a * b
    return total


@cocotb.test()
async def test_qk_dotprod_stream(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    dut.rst_n.value = 0
    dut.i_valid.value = 0
    dut.i_row1_valid.value = 0
    dut.i_q0_chunk_q8_8.value = 0
    dut.i_q1_chunk_q8_8.value = 0
    dut.i_k_chunk_q8_8.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    random.seed(20260309)
    pipe_lat = latency()
    expected = []

    for cycle in range(20):
        row1_valid = random.choice([0, 1])
        q0 = [random.randint(-128, 127) for _ in range(32)]
        q1 = [random.randint(-128, 127) for _ in range(32)]
        k = [random.randint(-128, 127) for _ in range(32)]
        dut.i_valid.value = 1
        dut.i_row1_valid.value = row1_valid
        dut.i_q0_chunk_q8_8.value = pack_lanes(q0)
        dut.i_q1_chunk_q8_8.value = pack_lanes(q1)
        dut.i_k_chunk_q8_8.value = pack_lanes(k)

        expected.append((cycle + pipe_lat, ref_dot(q0, k), ref_dot(q1, k) if row1_valid else 0))
        await RisingEdge(dut.clk)

        if int(dut.o_valid.value):
            due, ref0, ref1 = expected.pop(0)
            assert due <= cycle + 1
            got0 = to_signed(int(dut.o_partial_sum0.value), 40)
            got1 = to_signed(int(dut.o_partial_sum1.value), 40)
            assert got0 == ref0, f"sum0 mismatch got={got0} ref={ref0}"
            assert got1 == ref1, f"sum1 mismatch got={got1} ref={ref1}"

    dut.i_valid.value = 0
    for cycle in range(pipe_lat + 3):
        await RisingEdge(dut.clk)
        if int(dut.o_valid.value):
            _, ref0, ref1 = expected.pop(0)
            got0 = to_signed(int(dut.o_partial_sum0.value), 40)
            got1 = to_signed(int(dut.o_partial_sum1.value), 40)
            assert got0 == ref0
            assert got1 == ref1

    assert not expected, f"undrained expected outputs: {len(expected)}"
