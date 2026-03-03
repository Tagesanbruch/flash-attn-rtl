"""
Unit test for fa_dot_product_d.sv
Verifies serial dot product of two Q8.8 vectors with 40-bit accumulator.
"""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly


def to_s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def to_s40(v):
    v &= 0xFF_FFFF_FFFF
    return v - (1 << 40) if v & (1 << 39) else v


async def reset(dut):
    dut.rst_n.value = 0
    dut.i_start.value = 0
    dut.i_valid.value = 0
    dut.i_a_q8_8.value = 0
    dut.i_b_q8_8.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_dot_product(dut, a_vals, b_vals):
    """Drive a dot product and return (done, result)."""
    D = len(a_vals)
    dut.i_start.value = 1
    await RisingEdge(dut.clk)
    dut.i_start.value = 0

    for d in range(D):
        dut.i_valid.value = 1
        dut.i_a_q8_8.value = a_vals[d] & 0xFFFF
        dut.i_b_q8_8.value = b_vals[d] & 0xFFFF
        await RisingEdge(dut.clk)

    dut.i_valid.value = 0
    # o_done is registered, read after this edge settles
    await ReadOnly()
    done = int(dut.o_done.value)
    result = to_s40(int(dut.o_result.value))
    # Wait an extra cycle so we're out of ReadOnly before the next call
    await RisingEdge(dut.clk)
    return done, result


@cocotb.test()
async def test_zero_vectors(dut):
    """Dot product of zero vectors should be 0"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    D = 64
    a = [0] * D
    b = [0] * D
    done, result = await run_dot_product(dut, a, b)
    assert done == 1, "o_done should pulse"
    assert result == 0, f"Expected 0, got {result}"
    dut._log.info("test_zero_vectors PASS")


@cocotb.test()
async def test_identity_vectors(dut):
    """Dot product of [1.0, 0, 0, ...] . [1.0, 0, 0, ...] = 1.0 in Q16.16"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    D = 64
    ONE_Q8_8 = 256  # 1.0 in Q8.8
    a = [ONE_Q8_8] + [0] * (D - 1)
    b = [ONE_Q8_8] + [0] * (D - 1)
    done, result = await run_dot_product(dut, a, b)
    assert done == 1
    # 1.0 * 1.0 = 256 * 256 = 65536 = 1.0 in Q16.16
    assert result == 65536, f"Expected 65536, got {result}"
    dut._log.info("test_identity_vectors PASS")


@cocotb.test()
async def test_known_dot_product(dut):
    """Directed: a=[2.0, -1.5] padded, b=[3.0, 4.0] padded -> 6.0 + (-6.0) = 0"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    D = 64
    a = [512, -384] + [0] * (D - 2)
    b = [768, 1024] + [0] * (D - 2)
    done, result = await run_dot_product(dut, a, b)
    assert done == 1
    assert result == 0, f"Expected 0, got {result}"
    dut._log.info("test_known_dot_product PASS")


@cocotb.test()
async def test_random_dot_product(dut):
    """Random vectors: compare RTL vs Python golden"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    D = 64
    random.seed(12345)

    for trial in range(5):
        a = [random.randint(-128, 127) for _ in range(D)]
        b = [random.randint(-128, 127) for _ in range(D)]
        expected = sum(to_s16(a[i]) * to_s16(b[i]) for i in range(D))

        done, result = await run_dot_product(dut, a, b)
        assert done == 1, f"Trial {trial}: no done"
        assert result == expected, f"Trial {trial}: got {result}, expected {expected}"

    dut._log.info("test_random_dot_product PASS")


@cocotb.test()
async def test_consecutive_products(dut):
    """Start two dot products back to back"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    D = 64
    for trial in range(2):
        val = (trial + 1) * 256  # 1.0 or 2.0 in Q8.8
        expected = val * val * D

        a = [val] * D
        b = [val] * D
        done, result = await run_dot_product(dut, a, b)
        assert done == 1
        assert result == expected, f"Trial {trial}: got {result}, expected {expected}"

    dut._log.info("test_consecutive_products PASS")
