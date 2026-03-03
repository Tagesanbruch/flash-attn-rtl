"""
Unit test for fa_dma_writer.sv
Verifies AXI4 Master write DMA: command -> AW -> W data -> B response.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


async def reset(dut):
    dut.rst_n.value = 0
    dut.cmd_valid.value = 0
    dut.cmd_addr.value = 0
    dut.cmd_len.value = 0
    dut.in_valid.value = 0
    dut.in_data.value = 0
    dut.in_last.value = 0
    dut.m_axi_awready.value = 0
    dut.m_axi_wready.value = 0
    dut.m_axi_bid.value = 0
    dut.m_axi_bresp.value = 0
    dut.m_axi_bvalid.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_single_write_burst(dut):
    """Write a 4-beat burst and verify AW/W/B handshake"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    addr = 0x2000_0000
    burst_len = 3  # 4 beats

    # Issue command
    dut.cmd_valid.value = 1
    dut.cmd_addr.value = addr
    dut.cmd_len.value = burst_len
    await RisingEdge(dut.clk)
    assert int(dut.cmd_ready.value) == 1
    dut.cmd_valid.value = 0
    await RisingEdge(dut.clk)

    # Wait for AW valid
    for _ in range(5):
        if int(dut.m_axi_awvalid.value) == 1:
            break
        await RisingEdge(dut.clk)
    assert int(dut.m_axi_awvalid.value) == 1
    assert int(dut.m_axi_awaddr.value) == addr
    assert int(dut.m_axi_awlen.value) == burst_len

    # Accept AW
    dut.m_axi_awready.value = 1
    await RisingEdge(dut.clk)
    dut.m_axi_awready.value = 0
    await RisingEdge(dut.clk)

    # Now send W data with back-pressure
    dut.m_axi_wready.value = 1
    written_data = []
    for beat in range(burst_len + 1):
        dut.in_valid.value = 1
        dut.in_data.value = 0xCAFE_0000 + beat
        dut.in_last.value = 1 if beat == burst_len else 0
        await RisingEdge(dut.clk)
        if int(dut.m_axi_wvalid.value) == 1:
            written_data.append(int(dut.m_axi_wdata.value))
            # Check WLAST on last beat
            if beat == burst_len:
                assert int(dut.m_axi_wlast.value) == 1, "WLAST should be 1 on last beat"
    dut.in_valid.value = 0
    await RisingEdge(dut.clk)

    assert len(written_data) == burst_len + 1

    # Send B response
    dut.m_axi_bvalid.value = 1
    dut.m_axi_bresp.value = 0  # OKAY
    await RisingEdge(dut.clk)
    # Wait for bready
    for _ in range(5):
        if int(dut.m_axi_bready.value) == 1:
            break
        await RisingEdge(dut.clk)
    dut.m_axi_bvalid.value = 0
    await RisingEdge(dut.clk)

    # Should be back to IDLE
    assert int(dut.cmd_ready.value) == 1
    assert int(dut.error.value) == 0
    dut._log.info("test_single_write_burst PASS")


@cocotb.test()
async def test_write_error_flag(dut):
    """B response with error sets sticky error"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    # Issue 1-beat write
    dut.cmd_valid.value = 1
    dut.cmd_addr.value = 0x3000
    dut.cmd_len.value = 0  # 1 beat
    await RisingEdge(dut.clk)
    dut.cmd_valid.value = 0

    # Accept AW
    dut.m_axi_awready.value = 1
    for _ in range(5):
        if int(dut.m_axi_awvalid.value):
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.m_axi_awready.value = 0

    # Send W data
    dut.m_axi_wready.value = 1
    dut.in_valid.value = 1
    dut.in_data.value = 0x1234
    dut.in_last.value = 1
    await RisingEdge(dut.clk)
    dut.in_valid.value = 0
    await RisingEdge(dut.clk)

    # B with SLVERR
    dut.m_axi_bvalid.value = 1
    dut.m_axi_bresp.value = 2  # SLVERR
    for _ in range(5):
        if int(dut.m_axi_bready.value):
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.m_axi_bvalid.value = 0
    await RisingEdge(dut.clk)

    assert int(dut.error.value) == 1, "Error flag should be set"
    dut._log.info("test_write_error_flag PASS")


@cocotb.test()
async def test_byte_counter(dut):
    """wr_bytes increments per beat"""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset(dut)

    assert int(dut.wr_bytes.value) == 0

    # 2-beat write
    dut.cmd_valid.value = 1
    dut.cmd_addr.value = 0
    dut.cmd_len.value = 1
    await RisingEdge(dut.clk)
    dut.cmd_valid.value = 0

    dut.m_axi_awready.value = 1
    for _ in range(5):
        if int(dut.m_axi_awvalid.value):
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.m_axi_awready.value = 0

    dut.m_axi_wready.value = 1
    for beat in range(2):
        dut.in_valid.value = 1
        dut.in_data.value = beat
        dut.in_last.value = 1 if beat == 1 else 0
        await RisingEdge(dut.clk)
    dut.in_valid.value = 0
    await RisingEdge(dut.clk)

    # B response
    dut.m_axi_bvalid.value = 1
    dut.m_axi_bresp.value = 0
    for _ in range(5):
        if int(dut.m_axi_bready.value):
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.m_axi_bvalid.value = 0
    await RisingEdge(dut.clk)

    # 16 bytes/beat * 2 beats = 32
    assert int(dut.wr_bytes.value) == 32, f"wr_bytes={int(dut.wr_bytes.value)}"
    dut._log.info("test_byte_counter PASS")
