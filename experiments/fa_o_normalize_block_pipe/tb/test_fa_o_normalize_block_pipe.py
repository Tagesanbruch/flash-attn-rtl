import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


def latency() -> int:
    exp = os.environ.get("EXP_NAME", "base")
    return {"base": 1, "exp_a": 2, "exp_b": 2, "exp_c": 2, "exp_d": 2}[exp]


def to_signed(value: int, bits: int) -> int:
    mask = (1 << bits) - 1
    value &= mask
    if value & (1 << (bits - 1)):
        return value - (1 << bits)
    return value


def pack64(values):
    out = 0
    for idx, val in enumerate(values):
        out |= (val & ((1 << 64) - 1)) << (idx * 64)
    return out


def unpack16(value, lanes=8):
    return [to_signed(value >> (idx * 16), 16) for idx in range(lanes)]


def norm_lane(acc, recip, den_zero):
    if den_zero:
        return 32767 if acc >= 0 else -32768
    norm_mul = acc * recip
    norm_rounded = norm_mul + (1 << 31) if norm_mul >= 0 else norm_mul - (1 << 31)
    norm_result = norm_rounded >> 32
    if norm_result > 32767:
        return 32767
    if norm_result < -32768:
        return -32768
    return norm_result


@cocotb.test()
async def test_norm_pipe_stream(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    dut.rst_n.value = 0
    dut.i_valid.value = 0
    dut.i_den_zero.value = 0
    dut.i_recip_q16_16.value = 0
    dut.i_acc_flat.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    random.seed(20260309)
    expected = []
    pipe_lat = latency()

    for cycle in range(12):
        den_zero = 1 if cycle == 3 else 0
        recip = random.randint(1 << 15, (1 << 17) - 1)
        accs = [random.randint(-(1 << 20), (1 << 20) - 1) for _ in range(8)]
        ref = [norm_lane(acc, recip, den_zero) for acc in accs]
        expected.append((cycle + pipe_lat, ref))
        dut.i_valid.value = 1
        dut.i_den_zero.value = den_zero
        dut.i_recip_q16_16.value = recip
        dut.i_acc_flat.value = pack64(accs)

        await RisingEdge(dut.clk)

        if int(dut.o_valid.value):
            due, ref_out = expected.pop(0)
            assert due <= cycle + 1
            got = unpack16(int(dut.o_data_flat.value))
            assert got == ref_out, f"got={got} ref={ref_out}"

    dut.i_valid.value = 0
    for cycle in range(pipe_lat + 3):
        await RisingEdge(dut.clk)
        if int(dut.o_valid.value):
            _, ref_out = expected.pop(0)
            got = unpack16(int(dut.o_data_flat.value))
            assert got == ref_out

    assert not expected, f"undrained outputs: {len(expected)}"
