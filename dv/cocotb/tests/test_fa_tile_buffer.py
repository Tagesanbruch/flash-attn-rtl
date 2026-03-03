"""
Unit test for fa_tile_buffer.sv
Verifies ping-pong double-buffer write/read/swap behavior.
"""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


def to_s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


async def reset(dut):
    dut.rst_n.value = 0
    dut.swap.value = 0
    dut.wr_valid.value = 0
    dut.wr_data.value = 0
    dut.rd_row.value = 0
    dut.rd_col.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_fill_and_read(dut):
    """Fill bank0, swap, check read from bank0 (now active)"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    # Parameters (matching defaults: TILE_ROWS=64, D=64, BUS_W=128)
    TILE_ROWS = 64
    D = 64
    ELEMS_PER_BEAT = 8  # 128/16
    TOTAL_ELEMS = TILE_ROWS * D  # 4096
    TOTAL_BEATS = TOTAL_ELEMS // ELEMS_PER_BEAT  # 512

    random.seed(42)
    expected = [random.randint(-32768, 32767) for _ in range(TOTAL_ELEMS)]

    # Fill bank0 (fill_bank starts at 0)
    for beat in range(TOTAL_BEATS):
        pack = 0
        for i in range(ELEMS_PER_BEAT):
            idx = beat * ELEMS_PER_BEAT + i
            pack |= (expected[idx] & 0xFFFF) << (i * 16)
        dut.wr_valid.value = 1
        dut.wr_data.value = pack
        await RisingEdge(dut.clk)
    dut.wr_valid.value = 0
    await RisingEdge(dut.clk)

    # Swap: bank0 becomes active (readable)
    dut.swap.value = 1
    await RisingEdge(dut.clk)
    dut.swap.value = 0
    await RisingEdge(dut.clk)

    # Read back and verify a subset (checking every 64th element for speed)
    errors = 0
    for check_idx in range(0, TOTAL_ELEMS, 64):
        row = check_idx // D
        col = check_idx % D
        dut.rd_row.value = row
        dut.rd_col.value = col
        await RisingEdge(dut.clk)
        # Combinational read, check after settle
        await cocotb.triggers.Timer(1, units="ns")
        got = to_s16(int(dut.rd_data.value))
        exp = to_s16(expected[check_idx])
        if got != exp:
            dut._log.error(f"Mismatch at [{row}][{col}]: got={got}, exp={exp}")
            errors += 1
    assert errors == 0, f"{errors} read mismatches"
    dut._log.info("test_fill_and_read PASS")


@cocotb.test()
async def test_swap_independence(dut):
    """Verify that two banks are independent"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    ELEMS_PER_BEAT = 8
    # Write a small pattern to bank0 (just first beat)
    pack_a = 0
    for i in range(ELEMS_PER_BEAT):
        pack_a |= ((i + 1) & 0xFFFF) << (i * 16)
    dut.wr_valid.value = 1
    dut.wr_data.value = pack_a
    await RisingEdge(dut.clk)
    dut.wr_valid.value = 0
    await RisingEdge(dut.clk)

    # Swap: bank0 -> active, bank1 -> fill
    dut.swap.value = 1
    await RisingEdge(dut.clk)
    dut.swap.value = 0
    await RisingEdge(dut.clk)

    # Write different pattern to bank1
    pack_b = 0
    for i in range(ELEMS_PER_BEAT):
        pack_b |= ((0xFF - i) & 0xFFFF) << (i * 16)
    dut.wr_valid.value = 1
    dut.wr_data.value = pack_b
    await RisingEdge(dut.clk)
    dut.wr_valid.value = 0
    await RisingEdge(dut.clk)

    # Read from active bank (bank0): should see pattern A
    dut.rd_row.value = 0
    dut.rd_col.value = 0
    await cocotb.triggers.Timer(1, units="ns")
    got = to_s16(int(dut.rd_data.value))
    assert got == 1, f"Active bank should read 1, got {got}"

    # Swap again: bank1 -> active
    dut.swap.value = 1
    await RisingEdge(dut.clk)
    dut.swap.value = 0
    await RisingEdge(dut.clk)

    dut.rd_row.value = 0
    dut.rd_col.value = 0
    await cocotb.triggers.Timer(1, units="ns")
    got = to_s16(int(dut.rd_data.value))
    assert got == to_s16(0xFF), f"After 2nd swap, should read 0xFF pattern, got {got}"
    dut._log.info("test_swap_independence PASS")
