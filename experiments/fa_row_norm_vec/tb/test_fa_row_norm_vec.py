import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from fp_ref import recip_q16_16, to_s16, to_s32


def norm_lane_ref(acc_q16_16: int, recip_q16_16: int) -> int:
    norm_full = to_s32(acc_q16_16) * recip_q16_16
    norm_shifted = norm_full >> 16
    norm_s32 = to_s32(norm_shifted)
    if norm_s32 > 32767:
        return 32767
    if norm_s32 < -32768:
        return -32768
    return to_s16(norm_s32)


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.i_valid.value = 0
    dut.i_recip_q16_16.value = 0
    for idx in range(8):
        getattr(dut, f"i_acc{idx}_q16_16").value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def drive_vector(dut, accs, recip):
    dut.i_valid.value = 1
    dut.i_recip_q16_16.value = recip & 0xFFFFFFFF
    for idx, acc in enumerate(accs):
        getattr(dut, f"i_acc{idx}_q16_16").value = acc & 0xFFFFFFFF
    await RisingEdge(dut.clk)
    dut.i_valid.value = 0

    cycles = 0
    while True:
        await RisingEdge(dut.clk)
        cycles += 1
        if int(dut.o_valid.value) == 1:
            outs = [to_s16(int(getattr(dut, f"o_out{idx}_q8_8").value)) for idx in range(8)]
            return cycles, outs


@cocotb.test()
async def test_row_norm_vec_latency_and_values(dut):
    exp_name = os.environ.get("EXP_NAME", "base")
    expected_latency = 2 if exp_name == "exp_a" else 3

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    accs = [0x0001_0000, 0x0000_8000, -0x0000_C000, 0x0000_4000,
            -0x0001_8000, 0x0000_2000, 0x0002_0000, -0x0000_1000]
    recip = recip_q16_16(0x0002_0000)
    ref = [norm_lane_ref(acc, recip) for acc in accs]

    cycles, outs = await drive_vector(dut, accs, recip)
    assert cycles == expected_latency, f"latency mismatch got={cycles}, exp={expected_latency}"
    assert outs == ref, f"value mismatch got={outs}, ref={ref}"


@cocotb.test()
async def test_row_norm_vec_random(dut):
    exp_name = os.environ.get("EXP_NAME", "base")
    expected_latency = 2 if exp_name == "exp_a" else 3

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    random.seed(20260309)
    for _ in range(5):
        denom = random.randint(1 << 15, 1 << 18)
        recip = recip_q16_16(denom)
        accs = [random.randint(-(1 << 20), (1 << 20) - 1) for _ in range(8)]
        ref = [norm_lane_ref(acc, recip) for acc in accs]
        cycles, outs = await drive_vector(dut, accs, recip)
        assert cycles == expected_latency, f"random latency mismatch got={cycles}, exp={expected_latency}"
        assert outs == ref, f"random values mismatch got={outs}, ref={ref}"
