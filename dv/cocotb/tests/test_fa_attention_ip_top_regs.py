import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from axilite_master import AxiLiteMaster


REG_CTRL = 0x00
REG_STATUS = 0x04
REG_CFG = 0x08
REG_K_BASE_L = 0x1C
REG_K_BASE_H = 0x20
REG_V_BASE_L = 0x24
REG_V_BASE_H = 0x28
REG_O_BASE_L = 0x2C
REG_O_BASE_H = 0x30
REG_STRIDE_BYTES = 0x34
REG_NEG_LARGE = 0x38
REG_SCALE = 0x3C
REG_Q_BASE_L = 0x14
REG_Q_BASE_H = 0x18
REG_CYCLES = 0x40


@cocotb.test()
async def test_reg_rw_and_start_done(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())

    dut.rst_n.value = 0
    master = AxiLiteMaster(dut)
    await master.reset_master()
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    await master.write(REG_CFG, 0x1)
    cfg = await master.read(REG_CFG)
    assert (cfg & 0x1) == 0x1, f"CFG causal bit mismatch: {cfg:#x}"

    await master.write(REG_Q_BASE_L, 0x12345678)
    await master.write(REG_Q_BASE_H, 0x9ABCDEF0)
    ql = await master.read(REG_Q_BASE_L)
    qh = await master.read(REG_Q_BASE_H)
    assert ql == 0x12345678 and qh == 0x9ABCDEF0, "Q base register mismatch"

    await master.write(REG_CTRL, 0x1)

    saw_busy = False
    saw_done = False
    for _ in range(300):
        st = await master.read(REG_STATUS)
        busy = st & 0x1
        done = (st >> 1) & 0x1
        if busy:
            saw_busy = True
        if done:
            saw_done = True
            break
        await RisingEdge(dut.clk)

    assert saw_busy, "BUSY was never asserted"
    assert saw_done, "DONE was never asserted"

    cycles = await master.read(REG_CYCLES)
    assert cycles > 0, "CYCLES should be greater than zero"

    await master.write(REG_STATUS, 0x2)
    st2 = await master.read(REG_STATUS)
    done2 = (st2 >> 1) & 0x1
    assert done2 == 0, "DONE clear-by-write failed"


@cocotb.test()
async def test_reg_map_defaults_and_permissions(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())

    dut.rst_n.value = 0
    master = AxiLiteMaster(dut)
    await master.reset_master()
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    assert await master.read(REG_CTRL) == 0x00000000
    assert await master.read(REG_STATUS) == 0x00000000
    assert await master.read(REG_CFG) == 0x00000000
    assert await master.read(REG_Q_BASE_L) == 0x00000000
    assert await master.read(REG_Q_BASE_H) == 0x00000000
    assert await master.read(REG_K_BASE_L) == 0x00000000
    assert await master.read(REG_K_BASE_H) == 0x00000000
    assert await master.read(REG_V_BASE_L) == 0x00000000
    assert await master.read(REG_V_BASE_H) == 0x00000000
    assert await master.read(REG_O_BASE_L) == 0x00000000
    assert await master.read(REG_O_BASE_H) == 0x00000000
    assert await master.read(REG_STRIDE_BYTES) == 0x00000080
    assert await master.read(REG_NEG_LARGE) == 0xFFFF8000
    assert await master.read(REG_SCALE) == 0x00000020
    assert await master.read(REG_CYCLES) == 0x00000000

    # R/W fields
    await master.write(REG_CFG, 0x1)
    assert (await master.read(REG_CFG)) & 0x1 == 1

    await master.write(REG_Q_BASE_L, 0x11111111)
    await master.write(REG_Q_BASE_H, 0x22222222)
    await master.write(REG_K_BASE_L, 0x33333333)
    await master.write(REG_K_BASE_H, 0x44444444)
    await master.write(REG_V_BASE_L, 0x55555555)
    await master.write(REG_V_BASE_H, 0x66666666)
    await master.write(REG_O_BASE_L, 0x77777777)
    await master.write(REG_O_BASE_H, 0x88888888)
    await master.write(REG_STRIDE_BYTES, 0x00000100)
    await master.write(REG_NEG_LARGE, 0xFFFF0000)
    await master.write(REG_SCALE, 0x00000040)

    assert await master.read(REG_Q_BASE_L) == 0x11111111
    assert await master.read(REG_Q_BASE_H) == 0x22222222
    assert await master.read(REG_K_BASE_L) == 0x33333333
    assert await master.read(REG_K_BASE_H) == 0x44444444
    assert await master.read(REG_V_BASE_L) == 0x55555555
    assert await master.read(REG_V_BASE_H) == 0x66666666
    assert await master.read(REG_O_BASE_L) == 0x77777777
    assert await master.read(REG_O_BASE_H) == 0x88888888
    assert await master.read(REG_STRIDE_BYTES) == 0x00000100
    assert await master.read(REG_NEG_LARGE) == 0xFFFF0000
    assert await master.read(REG_SCALE) == 0x00000040

    # Read-only CYCLES should not be writable.
    await master.write(REG_CYCLES, 0xDEADBEEF)
    assert await master.read(REG_CYCLES) == 0x00000000

    # START should clear DONE sticky, DONE W1C should clear it.
    await master.write(REG_CTRL, 0x1)
    saw_done = False
    for _ in range(300):
        st = await master.read(REG_STATUS)
        if (st >> 1) & 0x1:
            saw_done = True
            break
        await RisingEdge(dut.clk)
    assert saw_done, "Expected DONE to be asserted"

    await master.write(REG_STATUS, 0x2)
    st = await master.read(REG_STATUS)
    assert ((st >> 1) & 0x1) == 0

    await master.write(REG_CTRL, 0x1)
    st_after_restart = await master.read(REG_STATUS)
    assert ((st_after_restart >> 1) & 0x1) == 0, "START should clear DONE sticky"
