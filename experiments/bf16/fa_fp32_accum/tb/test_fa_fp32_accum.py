import ctypes
import random
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.triggers import Timer


def bits_to_f32(bits: int) -> float:
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


def f32_to_bits(value: float) -> int:
    return struct.unpack('>I', struct.pack('>f', ctypes.c_float(value).value))[0]


def canonicalize_add(a_bits: int, b_bits: int, raw_bits: int) -> int:
    a_exp = (a_bits >> 23) & 0xFF
    a_frac = a_bits & 0x7FFFFF
    b_exp = (b_bits >> 23) & 0xFF
    b_frac = b_bits & 0x7FFFFF
    a_is_nan = a_exp == 0xFF and a_frac != 0
    b_is_nan = b_exp == 0xFF and b_frac != 0
    a_is_inf = a_exp == 0xFF and a_frac == 0
    b_is_inf = b_exp == 0xFF and b_frac == 0
    a_sign = (a_bits >> 31) & 0x1
    b_sign = (b_bits >> 31) & 0x1

    if a_is_nan or b_is_nan or (a_is_inf and b_is_inf and a_sign != b_sign):
        return 0x7FC00000
    return raw_bits & 0xFFFFFFFF


def add_ref(a_bits: int, b_bits: int) -> int:
    a = bits_to_f32(a_bits)
    b = bits_to_f32(b_bits)
    raw = f32_to_bits(a + b)
    return canonicalize_add(a_bits, b_bits, raw)


async def step_accum(dut, clear: int, hold: int, valid: int, x_bits: int):
    dut.i_clear.value = clear
    dut.i_hold.value = hold
    dut.i_valid.value = valid
    dut.i_x_fp32.value = x_bits
    await RisingEdge(dut.clk)
    await Timer(1, units="ps")
    return int(dut.o_acc_fp32.value) & 0xFFFFFFFF, int(dut.o_valid.value)


@cocotb.test()
async def test_fp32_accum_directed(dut):
    clock = Clock(dut.clk, 2, units="ns")
    cocotb.start_soon(clock.start())

    dut.rst_n.value = 0
    dut.i_clear.value = 0
    dut.i_hold.value = 0
    dut.i_valid.value = 0
    dut.i_x_fp32.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    acc_ref = 0
    sequence = [
        (1, 0, 1, 0x3F800000),
        (0, 0, 1, 0x40000000),
        (0, 1, 1, 0x40400000),
        (0, 0, 1, 0xBF800000),
        (1, 0, 1, 0x40400000),
        (0, 0, 1, 0x7F800000),
        (0, 0, 1, 0xFF800000),
    ]

    for clear, hold, valid, x_bits in sequence:
        base_ref = 0 if clear else acc_ref
        if valid and not hold:
            acc_ref = add_ref(base_ref, x_bits)
        elif clear:
            acc_ref = 0
        got_acc, got_valid = await step_accum(dut, clear, hold, valid, x_bits)
        assert got_acc == acc_ref, f"acc mismatch clear={clear} hold={hold} valid={valid} x=0x{x_bits:08x} got=0x{got_acc:08x} ref=0x{acc_ref:08x}"
        assert got_valid == int(valid and not hold)


@cocotb.test()
async def test_fp32_accum_random(dut):
    clock = Clock(dut.clk, 2, units="ns")
    cocotb.start_soon(clock.start())

    dut.rst_n.value = 0
    dut.i_clear.value = 0
    dut.i_hold.value = 0
    dut.i_valid.value = 0
    dut.i_x_fp32.value = 0
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
        if random.random() < 0.1:
            x_bits = random.choice([
                0x00000000,
                0x80000000,
                0x7F800000,
                0xFF800000,
                0x7FC00001,
                0x3F800000,
                0xBF800000,
            ])
        else:
            x_bits = random.randint(0, 0xFFFFFFFF)

        base_ref = 0 if clear else acc_ref
        if valid and not hold:
            acc_ref = add_ref(base_ref, x_bits)
        elif clear:
            acc_ref = 0

        got_acc, got_valid = await step_accum(dut, clear, hold, valid, x_bits)
        assert got_acc == acc_ref, f"acc mismatch clear={clear} hold={hold} valid={valid} x=0x{x_bits:08x} got=0x{got_acc:08x} ref=0x{acc_ref:08x}"
        assert got_valid == int(valid and not hold)
