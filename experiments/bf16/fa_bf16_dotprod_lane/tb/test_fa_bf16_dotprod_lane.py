import ctypes
import random
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from bf16.common.golden_models import bf16_mul_reference
from bf16.common.golden_models import fp32_add_bits
from bf16.common.golden_models import fp32_to_bf16_bits


def bits_to_f32(bits: int) -> float:
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


def f32_to_bits(value: float) -> int:
    return struct.unpack('>I', struct.pack('>f', ctypes.c_float(value).value))[0]


async def step_case(dut, clear: int, hold: int, valid: int, a_bf16: int, b_bf16: int):
    dut.i_clear.value = clear
    dut.i_hold.value = hold
    dut.i_valid.value = valid
    dut.i_a_bf16.value = a_bf16
    dut.i_b_bf16.value = b_bf16
    await Timer(1, units="ns")
    mul_fp32 = int(dut.o_mul_fp32.value) & 0xFFFFFFFF
    mul_bf16 = int(dut.o_mul_bf16.value) & 0xFFFF
    await RisingEdge(dut.clk)
    await Timer(1, units="ps")
    return {
        "mul_fp32": mul_fp32,
        "mul_bf16": mul_bf16,
        "acc_valid": int(dut.o_acc_valid.value),
        "acc_fp32": int(dut.o_acc_fp32.value) & 0xFFFFFFFF,
        "acc_bf16": int(dut.o_acc_bf16.value) & 0xFFFF,
    }


@cocotb.test()
async def test_bf16_dotprod_lane_directed(dut):
    clock = Clock(dut.clk, 2, units="ns")
    cocotb.start_soon(clock.start())
    dut.rst_n.value = 0
    dut.i_clear.value = 0
    dut.i_hold.value = 0
    dut.i_valid.value = 0
    dut.i_a_bf16.value = 0
    dut.i_b_bf16.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    acc_ref = 0
    seq = [
        (1, 0, 1, 0x3F80, 0x4000),
        (0, 0, 1, 0x3FC0, 0x3FC0),
        (0, 1, 1, 0x4000, 0x4000),
        (0, 0, 1, 0xBF80, 0x4000),
        (1, 0, 1, 0x7F80, 0x3F80),
    ]
    for clear, hold, valid, a_bf16, b_bf16 in seq:
        mul_fp32_ref, mul_bf16_ref = bf16_mul_reference(a_bf16, b_bf16)
        base_ref = 0 if clear else acc_ref
        if valid and not hold:
            acc_ref = fp32_add_bits(base_ref, mul_fp32_ref)
        elif clear:
            acc_ref = 0
        got = await step_case(dut, clear, hold, valid, a_bf16, b_bf16)
        assert got["mul_fp32"] == mul_fp32_ref
        assert got["mul_bf16"] == mul_bf16_ref
        assert got["acc_fp32"] == acc_ref
        assert got["acc_bf16"] == fp32_to_bf16_bits(acc_ref)
        assert got["acc_valid"] == int(valid and not hold)


@cocotb.test()
async def test_bf16_dotprod_lane_random(dut):
    clock = Clock(dut.clk, 2, units="ns")
    cocotb.start_soon(clock.start())
    dut.rst_n.value = 0
    dut.i_clear.value = 0
    dut.i_hold.value = 0
    dut.i_valid.value = 0
    dut.i_a_bf16.value = 0
    dut.i_b_bf16.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    random.seed(20260312)
    acc_ref = 0
    for _ in range(2000):
        clear = 1 if random.random() < 0.04 else 0
        hold = 1 if random.random() < 0.08 else 0
        valid = 1 if random.random() < 0.92 else 0
        a_bf16 = random.randint(0, 0xFFFF)
        b_bf16 = random.randint(0, 0xFFFF)
        mul_fp32_ref, mul_bf16_ref = bf16_mul_reference(a_bf16, b_bf16)
        base_ref = 0 if clear else acc_ref
        if valid and not hold:
            acc_ref = fp32_add_bits(base_ref, mul_fp32_ref)
        elif clear:
            acc_ref = 0
        got = await step_case(dut, clear, hold, valid, a_bf16, b_bf16)
        assert got["mul_fp32"] == mul_fp32_ref
        assert got["mul_bf16"] == mul_bf16_ref
        assert got["acc_fp32"] == acc_ref
        assert got["acc_bf16"] == fp32_to_bf16_bits(acc_ref)
        assert got["acc_valid"] == int(valid and not hold)
