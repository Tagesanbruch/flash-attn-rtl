import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import random
import math
import os

from axilite_master import AxiLiteMaster
from fp_ref import to_s16, to_u32, q8_8_mul_sat, exp_pwl_q1_15


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
REG_PERF_RUN_COUNT = 0x80
REG_PERF_BUSY_CYCLES = 0x84
REG_PERF_DMA_RD_CMD_COUNT = 0x88
REG_PERF_DMA_RD_BEAT_COUNT = 0x8C
REG_PERF_DMA_WR_CMD_COUNT = 0x90
REG_PERF_DMA_WR_BEAT_COUNT = 0x94
REG_PERF_COMP_LAUNCH_COUNT = 0x98
REG_PERF_EXP_EVAL_COUNT = 0x9C
REG_PERF_MUL_EVAL_COUNT = 0xA0
REG_PERF_RECIP_REQ_COUNT = 0xA4
REG_PERF_RECIP_RSP_COUNT = 0xA8
REG_PERF_MS_LOAD_Q_CYCLES = 0xAC
REG_PERF_MS_INIT_CONTEXT_CYCLES = 0xB0
REG_PERF_MS_LOAD_K_CYCLES = 0xB4
REG_PERF_MS_LOAD_V_CYCLES = 0xB8
REG_PERF_MS_COMPUTE_CYCLES = 0xBC
REG_PERF_MS_NORMALIZE_CYCLES = 0xC0
REG_PERF_MS_WRITE_O_CYCLES = 0xC4
REG_PERF_MS_NEXT_Q_CYCLES = 0xC8
REG_PERF_CS_DP_RUN_CYCLES = 0xCC
REG_PERF_CS_SCORE_DONE_CYCLES = 0xD0
REG_PERF_CS_SOFTMAX_PREP_CYCLES = 0xD4

S = 256
D = 64
BUS_W = 128
ELEMS_PER_BEAT = BUS_W // 16
TQ = 32
TK = 64
ROW_PAR = 2
DP_CHUNKS = D // 32


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


def _fixed_flash_attention_ref(Q, K, V, scale, neg_large, causal=False):
    out = [[0] * D for _ in range(S)]
    num_q_tiles = S // TQ
    num_k_tiles = S // TK

    for qt in range(num_q_tiles):
        q_start = qt * TQ
        row_m = [neg_large] * TQ
        row_l = [0] * TQ
        row_acc = [[0] * D for _ in range(TQ)]

        for kt in range(num_k_tiles):
            k_start = kt * TK
            for qi in range(TQ):
                for kj in range(TK):
                    dp = 0
                    for d in range(D):
                        dp += to_s16(Q[q_start + qi][d]) * to_s16(K[k_start + kj][d])

                    dp_q8_8 = (dp >> 8) & 0xFFFF
                    score = q8_8_mul_sat(to_s16(dp_q8_8), scale)

                    if causal and (q_start + qi) < (k_start + kj):
                        score = neg_large

                    m_old = row_m[qi]
                    m_new = score if score > m_old else m_old
                    diff_old = to_s16(m_old - m_new)
                    diff_new = to_s16(score - m_new)
                    exp_old = exp_pwl_q1_15(diff_old)
                    exp_new = exp_pwl_q1_15(diff_new)

                    l_scaled = (to_u32(row_l[qi]) * exp_old) >> 15
                    l_term = (exp_new << 1) & 0xFFFFFFFF
                    row_l[qi] = to_u32(l_scaled + l_term)

                    for d in range(D):
                        acc_scaled_wide = row_acc[qi][d] * exp_old
                        acc_old_sc = acc_scaled_wide >> 15
                        pv_mul = exp_new * to_s16(V[k_start + kj][d])
                        pv_term = pv_mul << 1
                        row_acc[qi][d] = acc_old_sc + pv_term

                    row_m[qi] = to_s16(m_new)

        for qi in range(TQ):
            den = to_u32(row_l[qi])
            for d in range(D):
                num = row_acc[qi][d]
                if den == 0:
                    norm_result = 32767 if num >= 0 else -32768
                else:
                    half = den >> 1
                    num_adj = num + half if num >= 0 else num - half
                    norm_result = int(num_adj / den)

                if norm_result > 32767:
                    out[q_start + qi][d] = 32767
                elif norm_result < -32768:
                    out[q_start + qi][d] = -32768
                else:
                    out[q_start + qi][d] = norm_result

    return out


def _calc_i16_metrics(got, ref):
    max_err = 0
    sum_abs_err = 0
    worst = None
    for i in range(S):
        for d in range(D):
            err = abs(to_s16(got[i][d]) - to_s16(ref[i][d]))
            sum_abs_err += err
            if err > max_err:
                max_err = err
                worst = (i, d, to_s16(got[i][d]), to_s16(ref[i][d]))
    mae = sum_abs_err / (S * D)
    return mae, max_err, worst


def _calc_fp32_metrics(got, ref_fp32):
    max_err = 0.0
    sum_abs_err = 0.0
    worst = None
    for i in range(S):
        for d in range(D):
            got_f = _q8_8_to_float(got[i][d])
            err = abs(got_f - ref_fp32[i][d])
            sum_abs_err += err
            if err > max_err:
                max_err = err
                worst = (i, d, got_f, ref_fp32[i][d])
    mae = sum_abs_err / (S * D)
    return mae, max_err, worst


def _dump_matrix_csv(path, mat):
    with open(path, "w") as f:
        for row in mat:
            f.write(",".join(str(v) for v in row))
            f.write("\n")


class AxiMemoryModel:
    def __init__(self, dut):
        self.dut = dut
        self.mem = {}
        self.rd_cmds = 0
        self.rd_beats = 0
        self.wr_cmds = 0
        self.wr_beats = 0

        self._rd_active = False
        self._rd_addr = 0
        self._rd_len = 0
        self._rd_idx = 0
        self._rd_just_started = False

        self._wr_active = False
        self._wr_addr = 0
        self._wr_len = 0
        self._wr_idx = 0
        self._wr_resp_pending = False

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

            if self._rd_active and int(self.dut.m_axi_rvalid.value) and int(self.dut.m_axi_rready.value):
                self.rd_beats += 1
                self._rd_idx += 1
                if self._rd_idx >= self._rd_len:
                    self._rd_active = False

            if self._wr_active and int(self.dut.m_axi_wvalid.value) and int(self.dut.m_axi_wready.value):
                addr = self._wr_addr + self._wr_idx * bytes_per_beat
                self.mem[addr] = int(self.dut.m_axi_wdata.value)
                self.wr_beats += 1
                self._wr_idx += 1
                if int(self.dut.m_axi_wlast.value) or self._wr_idx >= self._wr_len:
                    self._wr_active = False
                    self._wr_resp_pending = True

            if self._wr_resp_pending and int(self.dut.m_axi_bvalid.value) and int(self.dut.m_axi_bready.value):
                self._wr_resp_pending = False

            if (not self._rd_active) and int(self.dut.m_axi_arvalid.value) and int(self.dut.m_axi_arready.value):
                self._rd_active = True
                self._rd_addr = int(self.dut.m_axi_araddr.value)
                self._rd_len = int(self.dut.m_axi_arlen.value) + 1
                self._rd_idx = 0
                self._rd_just_started = True
                self.rd_cmds += 1

            if (not self._wr_active) and (not self._wr_resp_pending) and int(self.dut.m_axi_awvalid.value) and int(self.dut.m_axi_awready.value):
                self._wr_active = True
                self._wr_addr = int(self.dut.m_axi_awaddr.value)
                self._wr_len = int(self.dut.m_axi_awlen.value) + 1
                self._wr_idx = 0
                self.wr_cmds += 1

            self.dut.m_axi_arready.value = 0 if self._rd_active else 1
            self.dut.m_axi_awready.value = 0 if (self._wr_active or self._wr_resp_pending) else 1

            if self._rd_active and not self._rd_just_started:
                addr = self._rd_addr + self._rd_idx * bytes_per_beat
                self.dut.m_axi_rvalid.value = 1
                self.dut.m_axi_rdata.value = self.mem.get(addr, 0)
                self.dut.m_axi_rlast.value = 1 if (self._rd_idx + 1 == self._rd_len) else 0
            else:
                self.dut.m_axi_rvalid.value = 0
                self.dut.m_axi_rlast.value = 0

            if self._rd_just_started:
                self._rd_just_started = False

            self.dut.m_axi_wready.value = 1 if self._wr_active else 0
            self.dut.m_axi_bvalid.value = 1 if self._wr_resp_pending else 0


async def _capture_top_write_stream(dut, captured_beats):
    while True:
        await RisingEdge(dut.clk)
        if int(dut.dma_wr_in_valid.value) and int(dut.dma_wr_in_ready.value):
            captured_beats.append(int(dut.dma_wr_in_data.value))


async def _monitor_logical_read_stream(dut, mem, issues):
    bytes_per_beat = BUS_W // 8
    pending = []
    cmd_idx = 0
    beat_idx = 0
    while True:
        await RisingEdge(dut.clk)
        if int(dut.dma_rd_cmd_valid.value) and int(dut.dma_rd_cmd_ready.value):
            addr = int(dut.dma_rd_cmd_addr.value)
            beats = int(dut.dma_rd_cmd_len.value) + 1
            pending = [mem.mem.get(addr + i * bytes_per_beat, 0) for i in range(beats)]
            cmd_idx += 1
            beat_idx = 0

        if int(dut.dma_rd_out_valid.value) and int(dut.dma_rd_out_ready.value):
            if not pending:
                issues.append(("unexpected_data", cmd_idx, beat_idx, int(dut.dma_rd_out_data.value)))
                continue
            got = int(dut.dma_rd_out_data.value)
            exp = pending.pop(0)
            is_last = int(dut.dma_rd_out_last.value)
            exp_last = 1 if len(pending) == 0 else 0
            if got != exp:
                issues.append(("data_mismatch", cmd_idx, beat_idx, got, exp))
            if is_last != exp_last:
                issues.append(("last_mismatch", cmd_idx, beat_idx, is_last, exp_last))
            beat_idx += 1


def _unpack_beats_to_matrix(beats, rows, cols):
    out = [[0] * cols for _ in range(rows)]
    total_beats = rows * cols // ELEMS_PER_BEAT
    assert len(beats) >= total_beats, f"insufficient beats: {len(beats)} < {total_beats}"
    for beat_idx in range(total_beats):
        packed = beats[beat_idx]
        for e in range(ELEMS_PER_BEAT):
            flat = beat_idx * ELEMS_PER_BEAT + e
            out[flat // cols][flat % cols] = to_s16((packed >> (e * 16)) & 0xFFFF)
    return out


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


@cocotb.test(timeout_time=900000, timeout_unit="ms")
async def test_perf_counters_full_run(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())

    dut.rst_n.value = 0
    _init_dma_inputs(dut)
    master = AxiLiteMaster(dut)
    mem = AxiMemoryModel(dut)
    write_stream_beats = []
    read_stream_issues = []
    cocotb.start_soon(mem.run())
    cocotb.start_soon(_capture_top_write_stream(dut, write_stream_beats))
    cocotb.start_soon(_monitor_logical_read_stream(dut, mem, read_stream_issues))
    await master.reset_master()
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    seed = int(os.environ.get("TOP_TEST_SEED", "20260309"))
    data_min = int(os.environ.get("TOP_TEST_DATA_MIN", "-64"))
    data_max = int(os.environ.get("TOP_TEST_DATA_MAX", "64"))
    scale_q8_8 = int(os.environ.get("TOP_TEST_SCALE_Q8_8", "32"))
    neg_large_q8_8 = int(os.environ.get("TOP_TEST_NEG_LARGE_Q8_8", str(to_s16(0xE000))))
    causal = int(os.environ.get("TOP_TEST_CAUSAL", "1")) != 0
    cocotb.log.info(
        "top stimulus config: seed=%d range=[%d,%d] causal=%d scale_q8_8=%d neg_large_q8_8=%d",
        seed,
        data_min,
        data_max,
        int(causal),
        scale_q8_8,
        neg_large_q8_8,
    )
    random.seed(seed)
    q_base = 0x00000000
    k_base = 0x00010000
    v_base = 0x00020000
    o_base = 0x00030000
    stride_bytes = D * 2

    Q = [[random.randint(data_min, data_max) for _ in range(D)] for _ in range(S)]
    K = [[random.randint(data_min, data_max) for _ in range(D)] for _ in range(S)]
    V = [[random.randint(data_min, data_max) for _ in range(D)] for _ in range(S)]

    mem.store_matrix_q8_8(q_base, Q, stride_bytes)
    mem.store_matrix_q8_8(k_base, K, stride_bytes)
    mem.store_matrix_q8_8(v_base, V, stride_bytes)

    await master.write(REG_Q_BASE_L, q_base)
    await master.write(REG_Q_BASE_H, 0)
    await master.write(REG_K_BASE_L, k_base)
    await master.write(REG_K_BASE_H, 0)
    await master.write(REG_V_BASE_L, v_base)
    await master.write(REG_V_BASE_H, 0)
    await master.write(REG_O_BASE_L, o_base)
    await master.write(REG_O_BASE_H, 0)
    await master.write(REG_STRIDE_BYTES, stride_bytes)
    await master.write(REG_SCALE, scale_q8_8 & 0xFFFF)
    await master.write(REG_NEG_LARGE, neg_large_q8_8 & 0xFFFFFFFF)
    await master.write(REG_CFG, 0x1 if causal else 0x0)

    await master.write(REG_CTRL, 0x1)

    done_seen = False
    wait_internal_done = int(os.environ.get("TOP_WAIT_INTERNAL_DONE", "0")) != 0
    if wait_internal_done:
        for _ in range(15000 * 64):
            await RisingEdge(dut.clk)
            if int(dut.u_core.o_done.value):
                done_seen = True
                break
    else:
        for _ in range(15000):
            for _ in range(64):
                await RisingEdge(dut.clk)
            status = await master.read(REG_STATUS)
            if status & 0x2:
                done_seen = True
                break

    if not done_seen:
        try:
            cycles = await master.read(REG_CYCLES)
            status = await master.read(REG_STATUS)
            cocotb.log.error(
                "timeout debug: status=0x%08x cycles=%d core_busy=%d core_done=%d ms=%d cs=%d q_fill_cnt=%d rd_beats=%d wr_beats=%d rd_last=%d ar_state=%d",
                status,
                cycles,
                int(dut.u_core.o_busy.value),
                int(dut.u_core.o_done.value),
                int(dut.u_core.ms.value),
                int(dut.u_core.cs.value),
                int(dut.u_core.q_fill_cnt.value),
                mem.rd_beats,
                mem.wr_beats,
                int(dut.u_core.dma_rd_data_last.value),
                int(dut.u_dma_rd.ar_state.value),
            )
        except Exception:
            pass

    assert done_seen, "Timed out waiting for IP run completion"

    total_cycles = await master.read(REG_CYCLES)
    run_count = await master.read(REG_PERF_RUN_COUNT)
    busy_cycles = await master.read(REG_PERF_BUSY_CYCLES)
    dma_rd_cmd_count = await master.read(REG_PERF_DMA_RD_CMD_COUNT)
    dma_rd_beat_count = await master.read(REG_PERF_DMA_RD_BEAT_COUNT)
    dma_wr_cmd_count = await master.read(REG_PERF_DMA_WR_CMD_COUNT)
    dma_wr_beat_count = await master.read(REG_PERF_DMA_WR_BEAT_COUNT)
    comp_launch_count = await master.read(REG_PERF_COMP_LAUNCH_COUNT)
    exp_eval_count = await master.read(REG_PERF_EXP_EVAL_COUNT)
    mul_eval_count = await master.read(REG_PERF_MUL_EVAL_COUNT)
    recip_req_count = await master.read(REG_PERF_RECIP_REQ_COUNT)
    recip_rsp_count = await master.read(REG_PERF_RECIP_RSP_COUNT)
    ms_load_q_cycles = await master.read(REG_PERF_MS_LOAD_Q_CYCLES)
    ms_init_ctx_cycles = await master.read(REG_PERF_MS_INIT_CONTEXT_CYCLES)
    ms_load_k_cycles = await master.read(REG_PERF_MS_LOAD_K_CYCLES)
    ms_load_v_cycles = await master.read(REG_PERF_MS_LOAD_V_CYCLES)
    ms_compute_cycles = await master.read(REG_PERF_MS_COMPUTE_CYCLES)
    ms_normalize_cycles = await master.read(REG_PERF_MS_NORMALIZE_CYCLES)
    ms_write_o_cycles = await master.read(REG_PERF_MS_WRITE_O_CYCLES)
    ms_next_q_cycles = await master.read(REG_PERF_MS_NEXT_Q_CYCLES)
    cs_dp_run_cycles = await master.read(REG_PERF_CS_DP_RUN_CYCLES)
    cs_score_done_cycles = await master.read(REG_PERF_CS_SCORE_DONE_CYCLES)
    cs_softmax_prep_cycles = await master.read(REG_PERF_CS_SOFTMAX_PREP_CYCLES)

    cocotb.log.info(
        "perf summary: cycles=%d busy=%d rd_cmd=%d rd_beat=%d wr_cmd=%d wr_beat=%d comp_launch=%d exp=%d mul=%d recip_req=%d recip_rsp=%d",
        total_cycles,
        busy_cycles,
        dma_rd_cmd_count,
        dma_rd_beat_count,
        dma_wr_cmd_count,
        dma_wr_beat_count,
        comp_launch_count,
        exp_eval_count,
        mul_eval_count,
        recip_req_count,
        recip_rsp_count,
    )
    cocotb.log.info(
        "perf state cycles: load_q=%d init=%d load_k=%d load_v=%d compute=%d norm=%d write_o=%d next_q=%d dp=%d score=%d softmax=%d",
        ms_load_q_cycles,
        ms_init_ctx_cycles,
        ms_load_k_cycles,
        ms_load_v_cycles,
        ms_compute_cycles,
        ms_normalize_cycles,
        ms_write_o_cycles,
        ms_next_q_cycles,
        cs_dp_run_cycles,
        cs_score_done_cycles,
        cs_softmax_prep_cycles,
    )

    num_q_tiles = S // TQ
    num_k_tiles = S // TK
    q_beats_per_tile = TQ * D // ELEMS_PER_BEAT
    kv_beats_per_tile = TK * D // ELEMS_PER_BEAT
    qpair_per_compute = TQ // ROW_PAR
    qpair_batch = 4
    qpair_batches_per_compute = qpair_per_compute // qpair_batch
    qk_pipe_latency = 8
    qk_batch_cycles = qpair_batch * TK * DP_CHUNKS + qk_pipe_latency

    expected_comp_launch_count = num_q_tiles * num_k_tiles * 2
    expected_recip_count = S
    expected_cs_score_done = num_q_tiles * num_k_tiles * qpair_per_compute * TK
    expected_cs_softmax_prep = expected_cs_score_done
    expected_cs_dp_run = num_q_tiles * num_k_tiles * qpair_batches_per_compute * qk_batch_cycles
    expected_exp_eval = expected_cs_softmax_prep * 4
    expected_mul_eval = expected_cs_score_done * 2

    assert run_count == 1, f"run_count mismatch: {run_count}"
    assert dma_rd_cmd_count == mem.rd_cmds, \
        f"dma_rd_cmd_count mismatch: got {dma_rd_cmd_count}, obs {mem.rd_cmds}"
    assert dma_rd_beat_count == mem.rd_beats, \
        f"dma_rd_beat_count mismatch: got {dma_rd_beat_count}, obs {mem.rd_beats}"
    assert dma_wr_cmd_count == mem.wr_cmds, \
        f"dma_wr_cmd_count mismatch: got {dma_wr_cmd_count}, obs {mem.wr_cmds}"
    assert dma_wr_beat_count == mem.wr_beats, \
        f"dma_wr_beat_count mismatch: got {dma_wr_beat_count}, obs {mem.wr_beats}"
    assert comp_launch_count == expected_comp_launch_count, \
        f"comp_launch_count mismatch: got {comp_launch_count}, exp {expected_comp_launch_count}"
    assert recip_req_count == expected_recip_count, \
        f"recip_req_count mismatch: got {recip_req_count}, exp {expected_recip_count}"
    assert recip_rsp_count == expected_recip_count, \
        f"recip_rsp_count mismatch: got {recip_rsp_count}, exp {expected_recip_count}"
    assert cs_dp_run_cycles == expected_cs_dp_run, \
        f"cs_dp_run_cycles mismatch: got {cs_dp_run_cycles}, exp {expected_cs_dp_run}"
    assert cs_score_done_cycles == expected_cs_score_done, \
        f"cs_score_done_cycles mismatch: got {cs_score_done_cycles}, exp {expected_cs_score_done}"
    assert cs_softmax_prep_cycles == expected_cs_softmax_prep, \
        f"cs_softmax_prep_cycles mismatch: got {cs_softmax_prep_cycles}, exp {expected_cs_softmax_prep}"
    assert exp_eval_count == expected_exp_eval, \
        f"exp_eval_count mismatch: got {exp_eval_count}, exp {expected_exp_eval}"
    assert mul_eval_count == expected_mul_eval, \
        f"mul_eval_count mismatch: got {mul_eval_count}, exp {expected_mul_eval}"

    ms_sum = (
        ms_load_q_cycles
        + ms_init_ctx_cycles
        + ms_load_k_cycles
        + ms_load_v_cycles
        + ms_compute_cycles
        + ms_normalize_cycles
        + ms_write_o_cycles
        + ms_next_q_cycles
    )
    assert ms_sum == busy_cycles, f"master state sum mismatch: busy={busy_cycles}, sum={ms_sum}"
    assert ms_compute_cycles > ms_normalize_cycles > 0, "state occupancy ordering unexpected"
    assert ms_load_k_cycles > 0 and ms_load_v_cycles > 0 and ms_write_o_cycles > 0

    out = mem.load_matrix_q8_8(o_base, S, D, stride_bytes)
    stream_out = _unpack_beats_to_matrix(write_stream_beats, S, D)
    non_zero_outputs = sum(1 for row in out for v in row if v != 0)
    assert non_zero_outputs > 0, "output buffer should contain non-zero results after full run"

    stream_vs_mem_mae_lsb, stream_vs_mem_max_lsb, stream_vs_mem_worst = _calc_i16_metrics(stream_out, out)
    cocotb.log.info(
        "top write-path check (stream vs mem): mae_lsb=%.4f max_lsb=%d worst=%s",
        stream_vs_mem_mae_lsb,
        stream_vs_mem_max_lsb,
        stream_vs_mem_worst,
    )
    assert not read_stream_issues, f"logical read stream issues: {read_stream_issues[:5]}"

    dump_dir = os.environ.get("TOP_RTL_DUMP_DIR", "").strip()
    if dump_dir:
        os.makedirs(dump_dir, exist_ok=True)
        _dump_matrix_csv(os.path.join(dump_dir, "Q_q8_8.csv"), Q)
        _dump_matrix_csv(os.path.join(dump_dir, "K_q8_8.csv"), K)
        _dump_matrix_csv(os.path.join(dump_dir, "V_q8_8.csv"), V)
        _dump_matrix_csv(os.path.join(dump_dir, "O_top_q8_8.csv"), out)
        with open(os.path.join(dump_dir, "meta.txt"), "w") as f:
            f.write(f"seed={seed}\n")
            f.write(f"data_min={data_min}\n")
            f.write(f"data_max={data_max}\n")
            f.write(f"causal={int(causal)}\n")
            f.write(f"scale_q8_8={scale_q8_8}\n")
            f.write(f"neg_large_q8_8={neg_large_q8_8}\n")
        cocotb.log.info("top dump written to %s", dump_dir)

    golden_fixed = _fixed_flash_attention_ref(Q, K, V, scale=scale_q8_8, neg_large=to_s16(neg_large_q8_8), causal=causal)
    golden_fp32 = _fp32_ref(Q, K, V, causal=causal)

    mae_i16, max_err_i16, worst_i16 = _calc_i16_metrics(out, golden_fixed)
    mae_fp32, max_err_fp32, worst_fp32 = _calc_fp32_metrics(out, golden_fp32)

    cocotb.log.info(
        "top numeric check (rtl vs fixed-q8.8): mae_lsb=%.4f mae=%.6f max_err_lsb=%d max_err=%.6f worst=%s",
        mae_i16,
        mae_i16 / 256.0,
        max_err_i16,
        max_err_i16 / 256.0,
        worst_i16,
    )
    cocotb.log.info(
        "top numeric check (rtl vs fp32): mae=%.6f max_err=%.6f worst=%s",
        mae_fp32,
        max_err_fp32,
        worst_fp32,
    )
    assert max_err_i16 < 256, f"top output mismatch too large: max_err={max_err_i16}, worst={worst_i16}, mae={mae_i16:.4f}"
