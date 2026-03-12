import ctypes
import random
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


def bits_to_f32(bits: int) -> float:
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


def f32_to_bits(value: float) -> int:
    return struct.unpack('>I', struct.pack('>f', ctypes.c_float(value).value))[0]


def bf16_to_fp32_bits(x: int) -> int:
    return (x & 0xFFFF) << 16


def fp32_to_bf16_bits(x: int) -> int:
    sign = (x >> 31) & 0x1
    exp = (x >> 23) & 0xFF
    frac = x & 0x7FFFFF
    if exp == 0xFF and frac != 0:
        payload = (frac >> 16) & 0x7F
        if payload == 0:
            payload = 0x40
        return (sign << 15) | (0xFF << 7) | payload
    rounded = (x + 0x7FFF + ((x >> 16) & 1)) & 0xFFFFFFFF
    return (rounded >> 16) & 0xFFFF


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
    return canonicalize_add(a_bits, b_bits, f32_to_bits(bits_to_f32(a_bits) + bits_to_f32(b_bits)))


def mul_ref(a_bf16: int, b_bf16: int):
    a_f32 = bits_to_f32(bf16_to_fp32_bits(a_bf16))
    b_f32 = bits_to_f32(bf16_to_fp32_bits(b_bf16))
    prod_bits = f32_to_bits(a_f32 * b_f32)
    exp = (prod_bits >> 23) & 0xFF
    frac = prod_bits & 0x7FFFFF
    if exp == 0xFF and frac != 0:
        sign = ((a_bf16 >> 15) ^ (b_bf16 >> 15)) & 0x1
        prod_bits = (sign << 31) | 0x7FC00000
    return prod_bits, fp32_to_bf16_bits(prod_bits)


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
        mul_fp32_ref, mul_bf16_ref = mul_ref(a_bf16, b_bf16)
        base_ref = 0 if clear else acc_ref
        if valid and not hold:
            acc_ref = add_ref(base_ref, mul_fp32_ref)
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
        mul_fp32_ref, mul_bf16_ref = mul_ref(a_bf16, b_bf16)
        base_ref = 0 if clear else acc_ref
        if valid and not hold:
            acc_ref = add_ref(base_ref, mul_fp32_ref)
        elif clear:
            acc_ref = 0
        got = await step_case(dut, clear, hold, valid, a_bf16, b_bf16)
        assert got["mul_fp32"] == mul_fp32_ref
        assert got["mul_bf16"] == mul_bf16_ref
        assert got["acc_fp32"] == acc_ref
        assert got["acc_bf16"] == fp32_to_bf16_bits(acc_ref)
        assert got["acc_valid"] == int(valid and not hold)
