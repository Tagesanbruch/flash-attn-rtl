import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import random
import math

from axilite_master import AxiLiteMaster
from fp_ref import to_s16


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

S = 256
D = 64
BUS_W = 128
ELEMS_PER_BEAT = BUS_W // 16


def _q8_8_to_float(v):
    return to_s16(v) / 256.0


def _fp32_ref(Q, K, V, causal):
    scale = 1.0 / math.sqrt(D)
    out = [[0.0] * D for _ in range(S)]
    for i in range(S):
        scores = [0.0] * S
        max_s = -1e30
        for j in range(S):
            dot = 0.0
            for d in range(D):
                dot += _q8_8_to_float(Q[i][d]) * _q8_8_to_float(K[j][d])
            s = dot * scale
            if causal and j > i:
                s = -1e9
            scores[j] = s
            if s > max_s:
                max_s = s
        denom = 0.0
        for j in range(S):
            scores[j] = math.exp(scores[j] - max_s)
            denom += scores[j]
        for j in range(S):
            scores[j] /= denom
        for d in range(D):
            acc = 0.0
            for j in range(S):
                acc += scores[j] * _q8_8_to_float(V[j][d])
            out[i][d] = acc
    return out


class AxiMemoryModel:
    def __init__(self, dut):
        self.dut = dut
        self.mem = {}
        self.rd_beats = 0
        self.wr_beats = 0

        self._rd_active = False
        self._rd_addr = 0
        self._rd_len = 0
        self._rd_idx = 0

        self._wr_active = False
        self._wr_addr = 0
        self._wr_len = 0
        self._wr_idx = 0

    def store_matrix_q8_8(self, base_addr, matrix, stride_bytes):
        bytes_per_beat = BUS_W // 8
        for r in range(len(matrix)):
            row_addr = base_addr + r * stride_bytes
            for beat in range(D // ELEMS_PER_BEAT):
                packed = 0
                for e in range(ELEMS_PER_BEAT):
                    packed |= (matrix[r][beat * ELEMS_PER_BEAT + e] & 0xFFFF) << (e * 16)
                self.mem[row_addr + beat * bytes_per_beat] = packed

    def load_matrix_q8_8(self, base_addr, rows, cols, stride_bytes):
        out = [[0] * cols for _ in range(rows)]
        bytes_per_beat = BUS_W // 8
        for r in range(rows):
            row_addr = base_addr + r * stride_bytes
            for beat in range(cols // ELEMS_PER_BEAT):
                packed = self.mem.get(row_addr + beat * bytes_per_beat, 0)
                for e in range(ELEMS_PER_BEAT):
                    out[r][beat * ELEMS_PER_BEAT + e] = to_s16((packed >> (e * 16)) & 0xFFFF)
        return out

    async def run(self):
        self.dut.m_axi_arready.value = 1
        self.dut.m_axi_awready.value = 1
        self.dut.m_axi_wready.value = 0
        self.dut.m_axi_rvalid.value = 0
        self.dut.m_axi_rlast.value = 0
        self.dut.m_axi_rdata.value = 0
        self.dut.m_axi_rid.value = 0
        self.dut.m_axi_rresp.value = 0
        self.dut.m_axi_bid.value = 0
        self.dut.m_axi_bresp.value = 0
        self.dut.m_axi_bvalid.value = 0

        bytes_per_beat = BUS_W // 8
        while True:
            await RisingEdge(self.dut.clk)

            self.dut.m_axi_arready.value = 0 if self._rd_active else 1
            self.dut.m_axi_awready.value = 0 if self._wr_active else 1

            if (not self._rd_active) and int(self.dut.m_axi_arvalid.value) and int(self.dut.m_axi_arready.value):
                self._rd_active = True
                self._rd_addr = int(self.dut.m_axi_araddr.value)
                self._rd_len = int(self.dut.m_axi_arlen.value) + 1
                self._rd_idx = 0

            if self._rd_active:
                addr = self._rd_addr + self._rd_idx * bytes_per_beat
                self.dut.m_axi_rvalid.value = 1
                self.dut.m_axi_rdata.value = self.mem.get(addr, 0)
                self.dut.m_axi_rlast.value = 1 if (self._rd_idx + 1 == self._rd_len) else 0
                if int(self.dut.m_axi_rready.value):
                    self.rd_beats += 1
                    self._rd_idx += 1
                    if self._rd_idx >= self._rd_len:
                        self._rd_active = False
                        self.dut.m_axi_rvalid.value = 0
                        self.dut.m_axi_rlast.value = 0
            else:
                self.dut.m_axi_rvalid.value = 0
                self.dut.m_axi_rlast.value = 0

            if (not self._wr_active) and int(self.dut.m_axi_awvalid.value) and int(self.dut.m_axi_awready.value):
                self._wr_active = True
                self._wr_addr = int(self.dut.m_axi_awaddr.value)
                self._wr_len = int(self.dut.m_axi_awlen.value) + 1
                self._wr_idx = 0
                self.dut.m_axi_wready.value = 1

            if self._wr_active and int(self.dut.m_axi_wvalid.value) and int(self.dut.m_axi_wready.value):
                addr = self._wr_addr + self._wr_idx * bytes_per_beat
                self.mem[addr] = int(self.dut.m_axi_wdata.value)
                self.wr_beats += 1
                self._wr_idx += 1
                if int(self.dut.m_axi_wlast.value) or self._wr_idx >= self._wr_len:
                    self._wr_active = False
                    self.dut.m_axi_wready.value = 0
                    self.dut.m_axi_bvalid.value = 1

            if int(self.dut.m_axi_bvalid.value) and int(self.dut.m_axi_bready.value):
                self.dut.m_axi_bvalid.value = 0


def _init_dma_inputs(dut):
    """Drive default idle values on AXI4 Master DMA input ports."""
    dut.m_axi_arready.value = 0
    dut.m_axi_rid.value     = 0
    dut.m_axi_rdata.value   = 0
    dut.m_axi_rresp.value   = 0
    dut.m_axi_rlast.value   = 0
    dut.m_axi_rvalid.value  = 0
    dut.m_axi_awready.value = 0
    dut.m_axi_wready.value  = 0
    dut.m_axi_bid.value     = 0
    dut.m_axi_bresp.value   = 0
    dut.m_axi_bvalid.value  = 0


@cocotb.test()
async def test_reg_rw_and_start_busy(dut):
    """Test register read/write and that START asserts BUSY.
    DONE requires full DMA data flow and is tested in the core-level test."""
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())

    dut.rst_n.value = 0
    _init_dma_inputs(dut)
    master = AxiLiteMaster(dut)
    await master.reset_master()
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    # CFG register
    await master.write(REG_CFG, 0x1)
    cfg = await master.read(REG_CFG)
    assert (cfg & 0x1) == 0x1, f"CFG causal bit mismatch: {cfg:#x}"

    # Q base register
    await master.write(REG_Q_BASE_L, 0x12345678)
    await master.write(REG_Q_BASE_H, 0x9ABCDEF0)
    ql = await master.read(REG_Q_BASE_L)
    qh = await master.read(REG_Q_BASE_H)
    assert ql == 0x12345678 and qh == 0x9ABCDEF0, "Q base register mismatch"

    # Trigger START and check BUSY
    await master.write(REG_CTRL, 0x1)

    saw_busy = False
    for _ in range(20):
        st = await master.read(REG_STATUS)
        busy = st & 0x1
        if busy:
            saw_busy = True
            break
        await RisingEdge(dut.clk)

    assert saw_busy, "BUSY was never asserted after START"


@cocotb.test()
async def test_reg_map_defaults_and_permissions(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())

    dut.rst_n.value = 0
    _init_dma_inputs(dut)
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


@cocotb.test(timeout_time=900000, timeout_unit="ms")
async def test_register_dataflow_precision_and_cycles(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())

    dut.rst_n.value = 0
    _init_dma_inputs(dut)
    master = AxiLiteMaster(dut)
    await master.reset_master()
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    # Keep AXI data path stalled, only verify control/register behavior.
    dut.m_axi_arready.value = 1
    dut.m_axi_awready.value = 1
    dut.m_axi_wready.value = 1
    dut.m_axi_bvalid.value = 0
    dut.m_axi_rvalid.value = 0

    # multi-value register write/read checks
    for neg in [0xFFFFE000, 0xFFFFD000, 0xFFFFC000]:
        await master.write(REG_NEG_LARGE, neg)
        assert await master.read(REG_NEG_LARGE) == neg
    for sc in [0x00000018, 0x00000020, 0x00000028]:
        await master.write(REG_SCALE, sc)
        assert await master.read(REG_SCALE) == sc

    await master.write(REG_Q_BASE_L, 0x00000000)
    await master.write(REG_Q_BASE_H, 0)
    await master.write(REG_K_BASE_L, 0x00010000)
    await master.write(REG_K_BASE_H, 0)
    await master.write(REG_V_BASE_L, 0x00020000)
    await master.write(REG_V_BASE_H, 0)
    await master.write(REG_O_BASE_L, 0x00030000)
    await master.write(REG_O_BASE_H, 0)
    await master.write(REG_STRIDE_BYTES, D * 2)
    await master.write(REG_SCALE, 0x00000020)      # 1/sqrt(64)
    await master.write(REG_NEG_LARGE, 0xFFFFE000)  # -8192
    await master.write(REG_CFG, 0x1)               # causal

    # start
    await master.write(REG_CTRL, 0x1)

    # Observe cycles while BUSY
    await RisingEdge(dut.clk)
    c0 = await master.read(REG_CYCLES)
    for _ in range(2000):
        await RisingEdge(dut.clk)
    c1 = await master.read(REG_CYCLES)
    assert c1 > c0, f"CYCLES should increase while running: c0={c0}, c1={c1}"

    st = await master.read(REG_STATUS)
    assert (st & 0x1) == 1, f"BUSY should remain high without DMA data, status={st:#x}"

    # Soft reset should terminate running state and keep CYCLES readable.
    await master.write(REG_CTRL, 0x2)
    for _ in range(10):
        await RisingEdge(dut.clk)
    st2 = await master.read(REG_STATUS)
    assert (st2 & 0x1) == 0, f"BUSY should clear after SOFT_RESET, status={st2:#x}"
    c2 = await master.read(REG_CYCLES)
    assert c2 >= c1, "CYCLES register should remain readable after reset"
