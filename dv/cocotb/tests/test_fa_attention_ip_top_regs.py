import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from axilite_master import AxiLiteMaster


REG_CTRL = 0x00
REG_STATUS = 0x04
REG_CFG = 0x08
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
