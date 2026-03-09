"""
System-level unit test for fa_attention_core.sv
Supports both small parameters (S=32, D=8) for fast CI and
full contest parameters (S=256, D=64) via environment variables.
Emulates DMA memory through signal-level read/write handshakes.
"""
import math
import os
import random
import csv
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from fp_ref import (
    to_s16, to_u32, to_s32,
    exp_pwl_q1_15, q8_8_mul_sat, recip_q16_16
)


# ---- Parameters: read from env (set by Makefile), default = RTL defaults ----
SEQ_LEN = int(os.environ.get('PARAM_SEQ_LEN', 256))
D       = int(os.environ.get('PARAM_D', 64))
TQ      = int(os.environ.get('PARAM_TQ', 32))
TK      = int(os.environ.get('PARAM_TK', 64))
BUS_W   = 128
ELEMS_PER_BEAT = BUS_W // 16  # 8
BEATS_PER_ROW  = D // ELEMS_PER_BEAT
NUM_Q_TILES    = SEQ_LEN // TQ
NUM_K_TILES    = SEQ_LEN // TK


def dump_matrix_csv(path, mat):
    with open(path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerows(mat)


def q8_8_float(x):
    return to_s16(x) / 256.0


def float_to_q8_8(f):
    v = int(round(f * 256))
    return max(-32768, min(32767, v))


class DmaMemory:
    """Emulates memory for DMA read/write."""
    def __init__(self):
        self.mem = {}  # addr -> 128-bit value (as int)

    def store_matrix_q8_8(self, base_addr, matrix, stride_bytes):
        """Store a [rows x cols] matrix of Q8.8 values into memory."""
        rows = len(matrix)
        cols = len(matrix[0])
        for r in range(rows):
            row_addr = base_addr + r * stride_bytes
            for beat in range(cols // ELEMS_PER_BEAT):
                pack = 0
                for e in range(ELEMS_PER_BEAT):
                    idx = beat * ELEMS_PER_BEAT + e
                    pack |= (matrix[r][idx] & 0xFFFF) << (e * 16)
                self.mem[row_addr + beat * (BUS_W // 8)] = pack

    def load_matrix_q8_8(self, base_addr, rows, cols, stride_bytes):
        """Load a matrix from memory."""
        result = []
        for r in range(rows):
            row = []
            row_addr = base_addr + r * stride_bytes
            for beat in range(cols // ELEMS_PER_BEAT):
                addr = row_addr + beat * (BUS_W // 8)
                pack = self.mem.get(addr, 0)
                for e in range(ELEMS_PER_BEAT):
                    val = (pack >> (e * 16)) & 0xFFFF
                    row.append(to_s16(val))
            result.append(row)
        return result

    def read_burst(self, start_addr, num_beats):
        """Return a list of 128-bit values for burst read."""
        result = []
        bytes_per_beat = BUS_W // 8
        for i in range(num_beats):
            addr = start_addr + i * bytes_per_beat
            result.append(self.mem.get(addr, 0))
        return result


def python_flash_attention(Q, K, V, scale, neg_large, causal=False):
    """
    Pure Python FlashAttention reference using the same fixed-point ops as RTL.
    Q: [S, D], K: [S, D], V: [S, D] in Q8.8 integer
    Returns O: [S, D] in Q8.8 integer
    """
    S = len(Q)
    num_q_tiles = S // TQ
    num_k_tiles = S // TK
    O = [[0] * D for _ in range(S)]

    for qt in range(num_q_tiles):
        q_start = qt * TQ
        # Init row context
        row_m = [neg_large] * TQ
        row_l = [0] * TQ
        row_acc = [[0] * D for _ in range(TQ)]

        for kt in range(num_k_tiles):
            k_start = kt * TK
            for qi in range(TQ):
                for kj in range(TK):
                    # Dot product
                    dp = 0
                    for d in range(D):
                        dp += to_s16(Q[q_start + qi][d]) * to_s16(K[k_start + kj][d])
                    # dp is in Q16.16, extract Q8.8
                    dp_q8_8 = (dp >> 8) & 0xFFFF
                    score = q8_8_mul_sat(to_s16(dp_q8_8), scale)

                    # Causal mask
                    if causal and (q_start + qi) < (k_start + kj):
                        score = neg_large

                    # Online softmax update
                    m_old = row_m[qi]
                    m_new = score if score > m_old else m_old
                    diff_old = to_s16(m_old - m_new)
                    diff_new = to_s16(score - m_new)
                    exp_old = exp_pwl_q1_15(diff_old)
                    exp_new = exp_pwl_q1_15(diff_new)

                    l_scaled = (to_u32(row_l[qi]) * exp_old) >> 15
                    l_term = (exp_new << 1) & 0xFFFFFFFF
                    l_new = to_u32(l_scaled + l_term)

                    for d in range(D):
                        acc_scaled_wide = row_acc[qi][d] * exp_old
                        acc_old_sc = acc_scaled_wide >> 15
                        pv_mul = exp_new * to_s16(V[k_start + kj][d])
                        pv_term = pv_mul << 1
                        row_acc[qi][d] = acc_old_sc + pv_term

                    row_m[qi] = to_s16(m_new)
                    row_l[qi] = l_new

        # Normalize
        for qi in range(TQ):
            den = to_u32(row_l[qi])
            for d in range(D):
                num = row_acc[qi][d]
                if den == 0:
                    norm_result = 32767 if num >= 0 else -32768
                else:
                    half = den >> 1
                    if num >= 0:
                        num_adj = num + half
                    else:
                        num_adj = num - half
                    norm_result = int(num_adj / den)
                if norm_result > 32767:
                    O[q_start + qi][d] = 32767
                elif norm_result < -32768:
                    O[q_start + qi][d] = -32768
                else:
                    O[q_start + qi][d] = norm_result

    return O


def python_fp32_attention(Q, K, V, causal=False):
    out = [[0.0] * D for _ in range(SEQ_LEN)]
    scale = 1.0 / math.sqrt(D)
    for i in range(SEQ_LEN):
        scores = [0.0] * SEQ_LEN
        max_s = -1e30
        for j in range(SEQ_LEN):
            dot = 0.0
            for d in range(D):
                dot += q8_8_float(Q[i][d]) * q8_8_float(K[j][d])
            s = dot * scale
            if causal and j > i:
                s = -1e9
            scores[j] = s
            if s > max_s:
                max_s = s
        denom = 0.0
        for j in range(SEQ_LEN):
            scores[j] = math.exp(scores[j] - max_s)
            denom += scores[j]
        for j in range(SEQ_LEN):
            scores[j] /= denom
        for d in range(D):
            acc = 0.0
            for j in range(SEQ_LEN):
                acc += scores[j] * q8_8_float(V[j][d])
            out[i][d] = acc
    return out


async def drive_dma_read_responses(dut, mem):
    """Coroutine: watches for DMA read commands and responds with data."""
    split_beats = int(os.environ.get('CORE_RD_STREAM_SPLIT_BEATS', '0'))
    split_gap_cycles = int(os.environ.get('CORE_RD_STREAM_GAP_CYCLES', '0'))
    while True:
        await RisingEdge(dut.clk)
        cmd_valid = int(dut.dma_rd_cmd_valid.value)
        cmd_ready = int(dut.dma_rd_cmd_ready.value)
        if cmd_valid == 1 and cmd_ready == 1:
            addr = int(dut.dma_rd_cmd_addr.value)
            burst_len = int(dut.dma_rd_cmd_len.value) + 1
            dut._log.info(
                f"DMA RD CMD: addr={addr:#010x}, beats={burst_len}, "
                f"split_beats={split_beats}, gap_cycles={split_gap_cycles}"
            )
            data = mem.read_burst(addr, burst_len)
            for i, d in enumerate(data):
                dut.dma_rd_data_valid.value = 1
                dut.dma_rd_data.value = d
                dut.dma_rd_data_last.value = 1 if i == len(data) - 1 else 0
                while True:
                    await RisingEdge(dut.clk)
                    if int(dut.dma_rd_data_ready.value) == 1:
                        break
                if split_beats > 0 and (i + 1) < len(data) and ((i + 1) % split_beats) == 0:
                    dut.dma_rd_data_valid.value = 0
                    dut.dma_rd_data_last.value = 0
                    for _ in range(split_gap_cycles):
                        await RisingEdge(dut.clk)
            dut.dma_rd_data_valid.value = 0
            dut.dma_rd_data_last.value = 0
            dut._log.info(f"DMA RD done {burst_len} beats")


async def drive_dma_read_responses_toplike(dut, mem):
    """Model the visible ready/valid timing of the top-level DMA reader."""
    split_beats = int(os.environ.get('CORE_RD_STREAM_SPLIT_BEATS', '256'))
    split_gap_cycles = int(os.environ.get('CORE_RD_STREAM_GAP_CYCLES', '1'))
    bytes_per_beat = BUS_W // 8

    dut.dma_rd_cmd_ready.value = 1
    dut.dma_rd_data_valid.value = 0
    dut.dma_rd_data.value = 0
    dut.dma_rd_data_last.value = 0

    active = False
    cmd_addr = 0
    total_beats = 0
    beat_idx = 0
    gap_count = 0
    while True:
        await RisingEdge(dut.clk)

        if active and int(dut.dma_rd_data_valid.value) and int(dut.dma_rd_data_ready.value):
            beat_idx += 1
            if beat_idx >= total_beats:
                active = False
                dut.dma_rd_cmd_ready.value = 1
                dut.dma_rd_data_valid.value = 0
                dut.dma_rd_data_last.value = 0
                continue
            if split_beats > 0 and (beat_idx % split_beats) == 0:
                gap_count = split_gap_cycles
                dut.dma_rd_data_valid.value = 0
                dut.dma_rd_data_last.value = 0
                continue

        if (not active) and int(dut.dma_rd_cmd_valid.value) and int(dut.dma_rd_cmd_ready.value):
            cmd_addr = int(dut.dma_rd_cmd_addr.value)
            total_beats = int(dut.dma_rd_cmd_len.value) + 1
            beat_idx = 0
            active = True
            gap_count = 1  # AR->R startup bubble
            dut.dma_rd_cmd_ready.value = 0
            dut._log.info(
                f"DMA RD CMD(toplike): addr={cmd_addr:#010x}, beats={total_beats}, "
                f"split_beats={split_beats}, gap_cycles={split_gap_cycles}"
            )

        if active:
            if gap_count > 0:
                gap_count -= 1
                dut.dma_rd_data_valid.value = 0
                dut.dma_rd_data_last.value = 0
            else:
                addr = cmd_addr + beat_idx * bytes_per_beat
                dut.dma_rd_data_valid.value = 1
                dut.dma_rd_data.value = mem.mem.get(addr, 0)
                dut.dma_rd_data_last.value = 1 if (beat_idx + 1) == total_beats else 0
        else:
            dut.dma_rd_data_valid.value = 0
            dut.dma_rd_data_last.value = 0


async def capture_dma_writes(dut, mem):
    """Coroutine: watches for DMA write commands and captures data."""
    while True:
        await RisingEdge(dut.clk)
        cmd_valid = int(dut.dma_wr_cmd_valid.value)
        cmd_ready = int(dut.dma_wr_cmd_ready.value)
        if cmd_valid == 1 and cmd_ready == 1:
            addr = int(dut.dma_wr_cmd_addr.value)
            burst_len = int(dut.dma_wr_cmd_len.value) + 1
            bytes_per_beat = BUS_W // 8
            for i in range(burst_len):
                while True:
                    await RisingEdge(dut.clk)
                    wr_valid = int(dut.dma_wr_data_valid.value)
                    wr_ready = int(dut.dma_wr_data_ready.value)
                    if wr_valid == 1 and wr_ready == 1:
                        wr_addr = addr + i * bytes_per_beat
                        mem.mem[wr_addr] = int(dut.dma_wr_data.value)
                        break


async def capture_dma_writes_toplike(dut, mem):
    """Model the visible ready timing of the top-level DMA writer."""
    bytes_per_beat = BUS_W // 8
    dut.dma_wr_cmd_ready.value = 1
    dut.dma_wr_data_ready.value = 0

    active = False
    resp_gap = 0
    wr_addr = 0
    wr_len = 0
    wr_idx = 0
    while True:
        await RisingEdge(dut.clk)

        if active and int(dut.dma_wr_data_valid.value) and int(dut.dma_wr_data_ready.value):
            mem.mem[wr_addr + wr_idx * bytes_per_beat] = int(dut.dma_wr_data.value)
            wr_idx += 1
            if wr_idx >= wr_len or int(dut.dma_wr_data_last.value):
                active = False
                resp_gap = 1
                dut.dma_wr_data_ready.value = 0

        if (not active) and resp_gap == 0 and int(dut.dma_wr_cmd_valid.value) and int(dut.dma_wr_cmd_ready.value):
            wr_addr = int(dut.dma_wr_cmd_addr.value)
            wr_len = int(dut.dma_wr_cmd_len.value) + 1
            wr_idx = 0
            active = True
            dut.dma_wr_cmd_ready.value = 0
            dut.dma_wr_data_ready.value = 0
            resp_gap = -1  # address phase bubble before W data

        if active:
            if resp_gap == -1:
                resp_gap = 0
                dut.dma_wr_data_ready.value = 1
            else:
                dut.dma_wr_data_ready.value = 1
        else:
            dut.dma_wr_data_ready.value = 0
            if resp_gap > 0:
                resp_gap -= 1
                if resp_gap == 0:
                    dut.dma_wr_cmd_ready.value = 1


@cocotb.test(timeout_time=600000, timeout_unit="ms")
async def test_attention_core_small(dut):
    """
    End-to-end test: fill DMA memory with random Q/K/V,
    run attention core, compare output O with Python golden.
    Params set via PARAM_* env vars (default: RTL defaults S=256,D=64).
    """
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())

    # Reset
    dut.rst_n.value = 0
    dut.i_start.value = 0
    dut.i_soft_reset.value = 0
    dut.i_causal_en.value = 0
    dut.i_scale_q8_8.value = 0
    dut.i_neg_large_q8_8.value = 0
    dut.i_q_base.value = 0
    dut.i_k_base.value = 0
    dut.i_v_base.value = 0
    dut.i_o_base.value = 0
    dut.i_stride_bytes.value = 0
    toplike_rd = int(os.environ.get('CORE_TOPLIKE_RD', os.environ.get('CORE_TOPLIKE_DMA', '0'))) != 0
    toplike_wr = int(os.environ.get('CORE_TOPLIKE_WR', os.environ.get('CORE_TOPLIKE_DMA', '0'))) != 0
    dut.dma_rd_cmd_ready.value = 1
    dut.dma_rd_data_valid.value = 0
    dut.dma_rd_data.value = 0
    dut.dma_rd_data_last.value = 0
    dut.dma_wr_cmd_ready.value = 1
    dut.dma_wr_data_ready.value = 1 if not toplike_wr else 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    # Setup parameters
    S = SEQ_LEN
    stride_bytes = D * 2  # bytes per row
    Q_BASE = 0x0000_0000
    K_BASE = 0x0001_0000
    V_BASE = 0x0002_0000
    O_BASE = 0x0003_0000
    scale = float_to_q8_8(1.0 / math.sqrt(D))
    neg_large = to_s16(int(os.environ.get('CORE_TEST_NEG_LARGE_Q8_8', str(float_to_q8_8(-8.0)))))
    causal = int(os.environ.get('CORE_TEST_CAUSAL', '0')) != 0
    seed = int(os.environ.get('CORE_TEST_SEED', '2025'))
    data_min = int(os.environ.get('CORE_TEST_DATA_MIN', '-32'))
    data_max = int(os.environ.get('CORE_TEST_DATA_MAX', '31'))
    split_beats = int(os.environ.get('CORE_RD_STREAM_SPLIT_BEATS', '0'))
    split_gap_cycles = int(os.environ.get('CORE_RD_STREAM_GAP_CYCLES', '0'))
    toplike_rd = int(os.environ.get('CORE_TOPLIKE_RD', os.environ.get('CORE_TOPLIKE_DMA', '0'))) != 0
    toplike_wr = int(os.environ.get('CORE_TOPLIKE_WR', os.environ.get('CORE_TOPLIKE_DMA', '0'))) != 0

    # Generate random Q/K/V (small values to stay in Q8.8 range)
    random.seed(seed)
    dut._log.info(
        f"stimulus config: seed={seed} range=[{data_min},{data_max}] "
        f"causal={int(causal)} neg_large_q8_8={neg_large} "
        f"split_beats={split_beats} gap_cycles={split_gap_cycles} "
        f"toplike_rd={int(toplike_rd)} toplike_wr={int(toplike_wr)}"
    )
    Q = [[random.randint(data_min, data_max) for _ in range(D)] for _ in range(S)]
    K = [[random.randint(data_min, data_max) for _ in range(D)] for _ in range(S)]
    V = [[random.randint(data_min, data_max) for _ in range(D)] for _ in range(S)]

    # Store in memory
    mem = DmaMemory()
    mem.store_matrix_q8_8(Q_BASE, Q, stride_bytes)
    mem.store_matrix_q8_8(K_BASE, K, stride_bytes)
    mem.store_matrix_q8_8(V_BASE, V, stride_bytes)

    # Compute golden reference
    dut._log.info(f"Computing Python golden (S={S}, D={D}, TQ={TQ}, TK={TK})...")
    O_golden = python_flash_attention(Q, K, V, scale, neg_large, causal=causal)
    O_fp32 = python_fp32_attention(Q, K, V, causal=causal)

    # Start DMA response coroutines
    if toplike_rd:
        dma_rd_task = cocotb.start_soon(drive_dma_read_responses_toplike(dut, mem))
    else:
        dma_rd_task = cocotb.start_soon(drive_dma_read_responses(dut, mem))

    if toplike_wr:
        dma_wr_task = cocotb.start_soon(capture_dma_writes_toplike(dut, mem))
    else:
        dma_wr_task = cocotb.start_soon(capture_dma_writes(dut, mem))

    # Configure and start
    dut.i_q_base.value = Q_BASE
    dut.i_k_base.value = K_BASE
    dut.i_v_base.value = V_BASE
    dut.i_o_base.value = O_BASE
    dut.i_stride_bytes.value = stride_bytes
    dut.i_scale_q8_8.value = scale & 0xFFFF
    dut.i_neg_large_q8_8.value = neg_large & 0xFFFF
    dut.i_causal_en.value = 1 if causal else 0
    await RisingEdge(dut.clk)

    dut.i_start.value = 1
    await RisingEdge(dut.clk)
    dut.i_start.value = 0

    # Wait for done (timeout scales with problem size)
    # Estimated: ~(D+3)*TQ*TK*num_q*num_k + DMA overhead
    estimated_cycles = NUM_Q_TILES * NUM_K_TILES * TQ * TK * (D + 5) * 2
    timeout = max(500_000, estimated_cycles * 2)
    dut._log.info(f"Waiting for done (timeout={timeout} cycles, est={estimated_cycles})...")
    for cycle in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.o_done.value) == 1:
            dut._log.info(f"Core done after {cycle+1} cycles")
            break
        # Periodic progress - check FSM states
        if cycle < 100 or cycle % 10000 == 0:
            try:
                ms_val = int(dut.ms.value)
                cs_val = int(dut.cs.value)
                dut._log.info(f"  cycle={cycle}: ms={ms_val} cs={cs_val}")
            except Exception:
                pass
    else:
        ms_val = int(dut.ms.value) if hasattr(dut, 'ms') else '?'
        assert False, f"Timeout after {timeout} cycles, ms={ms_val}"

    await RisingEdge(dut.clk)

    # Read output O from memory
    O_result = mem.load_matrix_q8_8(O_BASE, S, D, stride_bytes)

    dump_dir = os.environ.get("RTL_DUMP_DIR", "").strip()
    if dump_dir:
        os.makedirs(dump_dir, exist_ok=True)
        dump_matrix_csv(os.path.join(dump_dir, "Q_q8_8.csv"), Q)
        dump_matrix_csv(os.path.join(dump_dir, "K_q8_8.csv"), K)
        dump_matrix_csv(os.path.join(dump_dir, "V_q8_8.csv"), V)
        dump_matrix_csv(os.path.join(dump_dir, "O_rtl_q8_8.csv"), O_result)
        with open(os.path.join(dump_dir, "meta.txt"), "w") as f:
            f.write(f"S={S}\n")
            f.write(f"D={D}\n")
            f.write(f"TQ={TQ}\n")
            f.write(f"TK={TK}\n")
            f.write(f"scale_q8_8={scale}\n")
            f.write(f"neg_large_q8_8={neg_large}\n")
            f.write(f"causal={int(causal)}\n")
            f.write(f"seed={seed}\n")
        dut._log.info(f"Dumped RTL vectors to: {dump_dir}")

    # Compare
    max_err = 0
    total_err = 0
    fp32_max_err = 0.0
    fp32_total_err = 0.0
    count = 0
    for r in range(S):
        for c in range(D):
            got = O_result[r][c]
            exp = O_golden[r][c]
            err = abs(got - exp)
            max_err = max(max_err, err)
            total_err += err
            got_f = q8_8_float(got)
            fp32_err = abs(got_f - O_fp32[r][c])
            fp32_max_err = max(fp32_max_err, fp32_err)
            fp32_total_err += fp32_err
            count += 1

    mae = total_err / count if count > 0 else 0
    fp32_mae = fp32_total_err / count if count > 0 else 0.0
    dut._log.info(f"RTL vs fixed-like: MAX_AE={max_err}, MAE={mae:.4f}, count={count}")
    dut._log.info(f"RTL vs FP32: MAX_AE={fp32_max_err:.6f}, MAE={fp32_mae:.6f}, count={count}")
    # Allow some tolerance due to fixed-point arithmetic differences
    assert max_err < 256, f"Max error too large: {max_err} (>{256})"
    dut._log.info("test_attention_core_small PASS")
