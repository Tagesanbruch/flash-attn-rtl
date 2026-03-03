"""
Unit test for fa_dma_reader.sv
Verifies AXI4 Master read DMA: command interface -> AR channel -> R data passthrough.
"""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


async def reset(dut):
    dut.rst_n.value = 0
    dut.cmd_valid.value = 0
    dut.cmd_addr.value = 0
    dut.cmd_len.value = 0
    dut.m_axi_arready.value = 0
    dut.m_axi_rid.value = 0
    dut.m_axi_rdata.value = 0
    dut.m_axi_rresp.value = 0
    dut.m_axi_rlast.value = 0
    dut.m_axi_rvalid.value = 0
    dut.out_ready.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_single_burst(dut):
    """Test a single burst read of 4 beats"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    addr = 0x1000_0000
    burst_len = 3  # 4 beats (ARLEN=3)

    # Issue command
    dut.cmd_valid.value = 1
    dut.cmd_addr.value = addr
    dut.cmd_len.value = burst_len
    await RisingEdge(dut.clk)
    assert dut.cmd_ready.value == 1, "cmd_ready should be 1 in IDLE"
    dut.cmd_valid.value = 0
    await RisingEdge(dut.clk)

    # Wait for AR to be presented
    for _ in range(5):
        if int(dut.m_axi_arvalid.value) == 1:
            break
        await RisingEdge(dut.clk)

    assert int(dut.m_axi_arvalid.value) == 1, "ARVALID should be asserted"
    assert int(dut.m_axi_araddr.value) == addr, f"ARADDR mismatch: {int(dut.m_axi_araddr.value):#x}"
    assert int(dut.m_axi_arlen.value) == burst_len
    assert int(dut.m_axi_arburst.value) == 1  # INCR

    # Accept AR
    dut.m_axi_arready.value = 1
    await RisingEdge(dut.clk)
    dut.m_axi_arready.value = 0
    await RisingEdge(dut.clk)

    # AR should de-assert, back to IDLE
    assert int(dut.m_axi_arvalid.value) == 0

    # Now send R data beats
    dut.out_ready.value = 1
    received = []
    for beat in range(burst_len + 1):
        dut.m_axi_rvalid.value = 1
        dut.m_axi_rdata.value = 0xDEAD_0000 + beat
        dut.m_axi_rresp.value = 0  # OKAY
        dut.m_axi_rlast.value = 1 if beat == burst_len else 0
        await RisingEdge(dut.clk)
        if int(dut.out_valid.value) == 1:
            received.append(int(dut.out_data.value))
    dut.m_axi_rvalid.value = 0
    await RisingEdge(dut.clk)

    assert len(received) == burst_len + 1, f"Expected {burst_len+1} beats, got {len(received)}"
    for i, d in enumerate(received):
        assert d == 0xDEAD_0000 + i, f"Beat {i} data mismatch"
    assert int(dut.error.value) == 0, "No error expected"
    dut._log.info("test_single_burst PASS")


@cocotb.test()
async def test_error_flag(dut):
    """Test that RRESP error sets sticky error flag"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    # Issue command
    dut.cmd_valid.value = 1
    dut.cmd_addr.value = 0x2000
    dut.cmd_len.value = 0  # 1 beat
    await RisingEdge(dut.clk)
    dut.cmd_valid.value = 0
    await RisingEdge(dut.clk)

    # Accept AR
    dut.m_axi_arready.value = 1
    for _ in range(5):
        if int(dut.m_axi_arvalid.value) == 1:
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.m_axi_arready.value = 0

    # Send R with SLVERR
    dut.out_ready.value = 1
    dut.m_axi_rvalid.value = 1
    dut.m_axi_rdata.value = 0xBAD
    dut.m_axi_rresp.value = 2  # SLVERR
    dut.m_axi_rlast.value = 1
    await RisingEdge(dut.clk)
    dut.m_axi_rvalid.value = 0
    await RisingEdge(dut.clk)

    assert int(dut.error.value) == 1, "Error flag should be sticky set"
    dut._log.info("test_error_flag PASS")


@cocotb.test()
async def test_byte_counter(dut):
    """Test rd_bytes counter increments correctly"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    assert int(dut.rd_bytes.value) == 0

    # Issue 1-beat burst
    dut.cmd_valid.value = 1
    dut.cmd_addr.value = 0
    dut.cmd_len.value = 1  # 2 beats
    await RisingEdge(dut.clk)
    dut.cmd_valid.value = 0

    # Accept AR
    dut.m_axi_arready.value = 1
    for _ in range(5):
        if int(dut.m_axi_arvalid.value):
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.m_axi_arready.value = 0

    # Send 2 beats
    dut.out_ready.value = 1
    for beat in range(2):
        dut.m_axi_rvalid.value = 1
        dut.m_axi_rdata.value = beat
        dut.m_axi_rresp.value = 0
        dut.m_axi_rlast.value = 1 if beat == 1 else 0
        await RisingEdge(dut.clk)
    dut.m_axi_rvalid.value = 0
    await RisingEdge(dut.clk)

    # 128-bit = 16 bytes per beat, 2 beats = 32 bytes
    assert int(dut.rd_bytes.value) == 32, f"rd_bytes={int(dut.rd_bytes.value)}, expected 32"
    dut._log.info("test_byte_counter PASS")


@cocotb.test()
async def test_back_to_back_commands(dut):
    """Test issuing commands back to back"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    for cmd_idx in range(3):
        addr = 0x1000 * (cmd_idx + 1)
        # Issue command
        dut.cmd_valid.value = 1
        dut.cmd_addr.value = addr
        dut.cmd_len.value = 0  # 1 beat
        await RisingEdge(dut.clk)
        dut.cmd_valid.value = 0

        # Accept AR
        dut.m_axi_arready.value = 1
        for _ in range(5):
            if int(dut.m_axi_arvalid.value):
                break
            await RisingEdge(dut.clk)
        assert int(dut.m_axi_araddr.value) == addr
        await RisingEdge(dut.clk)
        dut.m_axi_arready.value = 0

        # Send 1 R beat
        dut.out_ready.value = 1
        dut.m_axi_rvalid.value = 1
        dut.m_axi_rdata.value = cmd_idx
        dut.m_axi_rresp.value = 0
        dut.m_axi_rlast.value = 1
        await RisingEdge(dut.clk)
        dut.m_axi_rvalid.value = 0
        await RisingEdge(dut.clk)

    dut._log.info("test_back_to_back_commands PASS")
