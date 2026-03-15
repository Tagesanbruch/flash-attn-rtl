import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from fp8.cmodel.fp8_dma_cycle_model import Cfg, Fp8DmaCycleModel, ST_COMPUTE, ST_INIT_CTX, ST_NORMALIZE


BUS_W = 128
FP8_PER_BEAT = BUS_W // 8
I32_PER_BEAT = BUS_W // 32
STRICT_LOCKSTEP = True


def s16(v):
    v &= 0xFFFF
    return v if v < 0x8000 else v - 0x10000


def s32(v):
    v &= 0xFFFFFFFF
    return v if v < 0x80000000 else v - 0x100000000


def s64(v):
    v &= 0xFFFFFFFFFFFFFFFF
    return v if v < 0x8000000000000000 else v - 0x10000000000000000


def fp8_e4m3_to_q4_11(x):
    sign = (x >> 7) & 1
    exp = (x >> 3) & 0xF
    frac = x & 0x7
    if exp == 0:
        mag = frac << 2
    elif exp == 0xF:
        mag = 32767
    else:
        mag = (8 + frac) << (exp + 1)
        mag = min(mag, 32767)
    return -mag if sign else mag


def round_shift(v, sh, mode):
    if sh <= 0:
        return v
    t = v
    if mode == 1:
        if v >= 0:
            t += 1 << (sh - 1)
        else:
            t -= 1 << (sh - 1)
    return t >> sh


def exp2_approx_q0_15(delta_q8_11):
    d = delta_q8_11 >> 8
    if d >= 0:
        return 32767
    if d <= -15:
        return 0
    return 32767 >> (-d)


class DmaMem:
    def __init__(self):
        self.mem = {}

    def wr_beat(self, addr, beat):
        self.mem[addr] = beat & ((1 << BUS_W) - 1)

    def rd_beat(self, addr):
        return self.mem.get(addr, 0)

    def store_fp8_matrix(self, base, mat, stride):
        rows = len(mat)
        cols = len(mat[0])
        bytes_per_beat = BUS_W // 8
        beats = (cols + FP8_PER_BEAT - 1) // FP8_PER_BEAT
        for r in range(rows):
            row_addr = base + r * stride
            for b in range(beats):
                pack = 0
                for e in range(FP8_PER_BEAT):
                    c = b * FP8_PER_BEAT + e
                    v = mat[r][c] if c < cols else 0
                    pack |= (v & 0xFF) << (e * 8)
                self.wr_beat(row_addr + b * bytes_per_beat, pack)

    def load_i32_matrix(self, base, rows, cols, stride_bytes):
        out = [[0 for _ in range(cols)] for _ in range(rows)]
        bytes_per_beat = BUS_W // 8
        beats = (cols + I32_PER_BEAT - 1) // I32_PER_BEAT
        for r in range(rows):
            row_addr = base + r * stride_bytes
            for b in range(beats):
                pack = self.rd_beat(row_addr + b * bytes_per_beat)
                for e in range(I32_PER_BEAT):
                    c = b * I32_PER_BEAT + e
                    if c < cols:
                        out[r][c] = s32((pack >> (e * 32)) & 0xFFFFFFFF)
        return out


def ref_fp8_dma(q, k, v, s, d, tq, tk, scale, round_mode, sat):
    out = [[0 for _ in range(d)] for _ in range(s)]
    for qt in range(s // tq):
        row_m = [-(1 << 31) for _ in range(tq)]
        row_l = [0 for _ in range(tq)]
        row_acc = [[0 for _ in range(d)] for _ in range(tq)]

        for kt in range(s // tk):
            for qi in range(tq):
                gi = qt * tq + qi
                for kj in range(tk):
                    gj = kt * tk + kj
                    dot = 0
                    for dd in range(d):
                        dot += fp8_e4m3_to_q4_11(q[gi][dd]) * fp8_e4m3_to_q4_11(k[gj][dd])
                    score = round_shift(dot, 11, round_mode)
                    score = (score * scale) >> 14
                    if sat:
                        score = max(-2147483648, min(2147483647, score))
                    score = s32(score)

                    m_old = row_m[qi]
                    m_new = score if score > m_old else m_old
                    exp_old = exp2_approx_q0_15(m_old - m_new)
                    exp_new = exp2_approx_q0_15(score - m_new)

                    l_scaled = (row_l[qi] * exp_old) >> 15
                    l_new = l_scaled + (exp_new << 1)

                    for dd in range(d):
                        acc_scaled = (row_acc[qi][dd] * exp_old) >> 15
                        v_term = fp8_e4m3_to_q4_11(v[gj][dd]) * exp_new
                        row_acc[qi][dd] = acc_scaled + v_term

                    row_m[qi] = m_new
                    row_l[qi] = l_new

        for qi in range(tq):
            gi = qt * tq + qi
            den = row_l[qi]
            for dd in range(d):
                out[gi][dd] = 0 if den == 0 else s32(int(row_acc[qi][dd] / den))

    return out


def ref_row_state(q, k, v, gi, s, d, scale, round_mode, sat):
    m = -(1 << 31)
    l = 0
    acc = [0 for _ in range(d)]
    for gj in range(s):
        dot = 0
        for dd in range(d):
            dot += fp8_e4m3_to_q4_11(q[gi][dd]) * fp8_e4m3_to_q4_11(k[gj][dd])
        score = round_shift(dot, 11, round_mode)
        score = (score * scale) >> 14
        if sat:
            score = max(-2147483648, min(2147483647, score))
        score = s32(score)

        m_new = score if score > m else m
        exp_old = exp2_approx_q0_15(m - m_new)
        exp_new = exp2_approx_q0_15(score - m_new)
        l_scaled = (l * exp_old) >> 15
        l = l_scaled + (exp_new << 1)
        for dd in range(d):
            acc_scaled = (acc[dd] * exp_old) >> 15
            acc[dd] = acc_scaled + fp8_e4m3_to_q4_11(v[gj][dd]) * exp_new
        m = m_new
    return m, l, acc


async def dma_driver(dut, mem: DmaMem):
    dut.dma_rd_cmd_ready.value = 1
    dut.dma_wr_cmd_ready.value = 1
    dut.dma_wr_data_ready.value = 1
    dut.dma_rd_data_valid.value = 0
    dut.dma_rd_data_last.value = 0
    dut.dma_rd_data.value = 0

    bytes_per_beat = BUS_W // 8
    pending_rd = None
    pending_wr = None

    while True:
        await RisingEdge(dut.i_clk)

        # Advance read stream on the handshake observed at this edge.
        if pending_rd is not None:
            addr, beats, idx, warmup, valid = pending_rd
            if valid and int(dut.dma_rd_data_ready.value):
                idx += 1
                if idx >= beats:
                    pending_rd = None
                    valid = 0
                    dut.dma_rd_data_valid.value = 0
                    dut.dma_rd_data_last.value = 0
                else:
                    pending_rd = [addr, beats, idx, warmup, 0]

        if int(dut.dma_rd_cmd_valid.value) and int(dut.dma_rd_cmd_ready.value):
            addr = int(dut.dma_rd_cmd_addr.value)
            beats = int(dut.dma_rd_cmd_len.value) + 1
            pending_rd = [addr, beats, 0, 1, 0]

        if pending_rd is not None:
            addr, beats, idx, warmup, valid = pending_rd
            if warmup > 0:
                dut.dma_rd_data_valid.value = 0
                dut.dma_rd_data_last.value = 0
                pending_rd = [addr, beats, idx, warmup - 1, 0]
            else:
                dut.dma_rd_data_valid.value = 1
                dut.dma_rd_data.value = mem.rd_beat(addr + idx * bytes_per_beat)
                dut.dma_rd_data_last.value = 1 if idx + 1 == beats else 0
                pending_rd = [addr, beats, idx, 0, 1]

        if int(dut.dma_wr_cmd_valid.value) and int(dut.dma_wr_cmd_ready.value):
            addr = int(dut.dma_wr_cmd_addr.value)
            beats = int(dut.dma_wr_cmd_len.value) + 1
            pending_wr = [addr, beats, 0]

        if pending_wr is not None and int(dut.dma_wr_data_valid.value) and int(dut.dma_wr_data_ready.value):
            addr, beats, idx = pending_wr
            mem.wr_beat(addr + idx * bytes_per_beat, int(dut.dma_wr_data.value))
            idx += 1
            if idx >= beats:
                pending_wr = None
            else:
                pending_wr = [addr, beats, idx]


@cocotb.test(timeout_time=120000, timeout_unit="ms")
async def test_fp8_attention_core_full_dma_end2end(dut):
    cocotb.start_soon(Clock(dut.i_clk, 2, units="ns").start())

    dut.i_rst_n.value = 0
    dut.i_start.value = 0
    dut.i_seq_len.value = 64
    dut.i_head_dim.value = 32
    dut.i_stride_bytes.value = 32
    dut.i_q_base.value = 0
    dut.i_k_base.value = 0x10000
    dut.i_v_base.value = 0x20000
    dut.i_o_base.value = 0x30000
    dut.i_score_scale_q1_14.value = 1 << 14
    dut.i_round_mode.value = 0
    dut.i_saturate_en.value = 1

    for _ in range(5):
        await RisingEdge(dut.i_clk)
    dut.i_rst_n.value = 1

    s = 64
    d = 32
    tq = 32
    tk = 64
    stride = d
    o_stride = d * 4
    seed = 20260315
    rng = random.Random(seed)

    q = [[rng.randrange(0, 256) for _ in range(d)] for _ in range(s)]
    k = [[rng.randrange(0, 256) for _ in range(d)] for _ in range(s)]
    v = [[rng.randrange(0, 256) for _ in range(d)] for _ in range(s)]

    mem = DmaMem()
    mem.store_fp8_matrix(0, q, stride)
    mem.store_fp8_matrix(0x10000, k, stride)
    mem.store_fp8_matrix(0x20000, v, stride)

    cocotb.start_soon(dma_driver(dut, mem))

    ref = ref_fp8_dma(q, k, v, s, d, tq, tk, 1 << 14, 0, 1)
    last_qt_row0 = (s // tq - 1) * tq
    ref_m0, ref_l0, ref_acc0 = ref_row_state(q, k, v, last_qt_row0, s, d, 1 << 14, 0, 1)

    cmodel = Fp8DmaCycleModel(
        Cfg(seq_len=s, head_dim=d, score_scale_q1_14=1 << 14, round_mode=0, saturate_en=1, tq=tq, tk=tk),
        q,
        k,
        v,
    )

    await RisingEdge(dut.i_clk)
    dut.i_start.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_start.value = 0
    await ReadOnly()
    cmodel.step(
        1,
        rd_cmd_hs=int(dut.dma_rd_cmd_valid.value) and int(dut.dma_rd_cmd_ready.value),
        rd_data_hs=int(dut.dma_rd_data_valid.value) and int(dut.dma_rd_data_ready.value),
        wr_cmd_hs=int(dut.dma_wr_cmd_valid.value) and int(dut.dma_wr_cmd_ready.value),
        wr_data_hs=int(dut.dma_wr_data_valid.value) and int(dut.dma_wr_data_ready.value),
    )
    if STRICT_LOCKSTEP:
        cmodel.step(
            0,
            rd_cmd_hs=int(dut.dma_rd_cmd_valid.value) and int(dut.dma_rd_cmd_ready.value),
            rd_data_hs=int(dut.dma_rd_data_valid.value) and int(dut.dma_rd_data_ready.value),
            wr_cmd_hs=int(dut.dma_wr_cmd_valid.value) and int(dut.dma_wr_cmd_ready.value),
            wr_data_hs=int(dut.dma_wr_data_valid.value) and int(dut.dma_wr_data_ready.value),
        )

    done = False
    for _ in range(30000):
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        snap = cmodel.snapshot()
        st_hw = int(dut.o_dbg_state.value)
        qt_hw = int(dut.o_dbg_qt.value)
        kt_hw = int(dut.o_dbg_kt.value)
        rd_idx_hw = int(dut.o_dbg_rd_beat_idx.value)
        wr_idx_hw = int(dut.o_dbg_wr_beat_idx.value)
        if STRICT_LOCKSTEP:
            if st_hw >= ST_COMPUTE and snap["state"] >= ST_COMPUTE:
                assert st_hw == snap["state"], f"state mismatch cyc={snap['cycle']} hw={st_hw} cm={snap['state']}"
                assert qt_hw == snap["qt"], f"qt mismatch cyc={snap['cycle']} st={st_hw} hw={qt_hw} cm={snap['qt']}"
                assert kt_hw == snap["kt"], f"kt mismatch cyc={snap['cycle']} st={st_hw} hw={kt_hw} cm={snap['kt']}"

        if STRICT_LOCKSTEP and snap["state"] == ST_COMPUTE:
            q00_hw = int(dut.o_dbg_q00.value)
            k00_hw = int(dut.o_dbg_k00.value)
            v00_hw = int(dut.o_dbg_v00.value)
            assert q00_hw == snap["q00"], f"q00 mismatch cyc={snap['cycle']} hw={q00_hw} cm={snap['q00']}"
            assert k00_hw == snap["k00"], f"k00 mismatch cyc={snap['cycle']} hw={k00_hw} cm={snap['k00']}"
            assert v00_hw == snap["v00"], f"v00 mismatch cyc={snap['cycle']} hw={v00_hw} cm={snap['v00']}"

        if STRICT_LOCKSTEP and ST_INIT_CTX <= snap["state"] <= ST_NORMALIZE:
            qlast_hw = int(dut.o_dbg_q_last.value)
            assert qlast_hw == snap["q_last"], (
                f"q_last mismatch cyc={snap['cycle']} st={st_hw} qt={qt_hw} kt={kt_hw} "
                f"hd={int(dut.i_head_dim.value)} hw={qlast_hw} cm={snap['q_last']} "
                f"q31_15={int(dut.o_dbg_q31_15.value)} q31_31={int(dut.o_dbg_q31_31.value)} "
                f"qsum_hw={int(dut.o_dbg_q_sum.value)} qsum_cm={snap['q_sum']} "
                f"last_qbeat_idx={int(dut.o_dbg_q_load_idx.value)} "
                f"last_qbeat_b0={int(dut.o_dbg_q_load_b0.value)} "
                f"last_qbeat_b15={int(dut.o_dbg_q_load_b15.value)}"
            )

        if STRICT_LOCKSTEP and snap["state"] in (ST_COMPUTE, ST_NORMALIZE):
            qlast_hw = int(dut.o_dbg_q_last.value)
            klast_hw = int(dut.o_dbg_k_last.value)
            vlast_hw = int(dut.o_dbg_v_last.value)
            assert klast_hw == snap["k_last"], f"k_last mismatch cyc={snap['cycle']} hw={klast_hw} cm={snap['k_last']}"
            assert vlast_hw == snap["v_last"], f"v_last mismatch cyc={snap['cycle']} hw={vlast_hw} cm={snap['v_last']}"

            qsum_hw = int(dut.o_dbg_q_sum.value)
            ksum_hw = int(dut.o_dbg_k_sum.value)
            vsum_hw = int(dut.o_dbg_v_sum.value)
            assert qsum_hw == snap["q_sum"], f"q_sum mismatch cyc={snap['cycle']} hw={qsum_hw} cm={snap['q_sum']}"
            assert ksum_hw == snap["k_sum"], f"k_sum mismatch cyc={snap['cycle']} hw={ksum_hw} cm={snap['k_sum']}"
            assert vsum_hw == snap["v_sum"], f"v_sum mismatch cyc={snap['cycle']} hw={vsum_hw} cm={snap['v_sum']}"

            m0_hw = s32(int(dut.o_dbg_m0.value))
            l0_hw = int(dut.o_dbg_l0.value)
            a00_hw = s64(int(dut.o_dbg_acc00.value))
            assert m0_hw == s32(snap["m0"]), (
                f"m0 mismatch cyc={snap['cycle']} st={st_hw} qt={qt_hw} kt={kt_hw} "
                f"hw={m0_hw} cm={s32(snap['m0'])} q00={int(dut.o_dbg_q00.value)} k00={int(dut.o_dbg_k00.value)}"
            )
            assert l0_hw == (snap["l0"] & 0xFFFFFFFF), f"l0 mismatch cyc={snap['cycle']} hw={l0_hw} cm={snap['l0'] & 0xFFFFFFFF}"
            assert a00_hw == s64(snap["acc00"]), f"acc00 mismatch cyc={snap['cycle']} hw={a00_hw} cm={s64(snap['acc00'])}"

        if STRICT_LOCKSTEP and st_hw >= ST_COMPUTE and snap["state"] >= ST_COMPUTE:
            assert int(dut.o_perf_rd_cmd.value) == snap["perf_rd_cmd"]
            assert int(dut.o_perf_wr_cmd.value) == snap["perf_wr_cmd"]
            assert int(dut.o_perf_compute_cycles.value) == snap["perf_compute_cycles"]
            assert int(dut.o_perf_softmax_updates.value) == snap["perf_softmax_updates"]

        if int(dut.o_done.value):
            done = True
            break

        cmodel.step(
            int(dut.i_start.value),
            rd_cmd_hs=int(dut.dma_rd_cmd_valid.value) and int(dut.dma_rd_cmd_ready.value),
            rd_data_hs=int(dut.dma_rd_data_valid.value) and int(dut.dma_rd_data_ready.value),
            wr_cmd_hs=int(dut.dma_wr_cmd_valid.value) and int(dut.dma_wr_cmd_ready.value),
            wr_data_hs=int(dut.dma_wr_data_valid.value) and int(dut.dma_wr_data_ready.value),
        )
    assert done, (
        "timeout waiting for done "
        f"st={int(dut.o_dbg_state.value)} qt={int(dut.o_dbg_qt.value)} kt={int(dut.o_dbg_kt.value)} "
        f"rd_idx={int(dut.o_dbg_rd_beat_idx.value)} wr_idx={int(dut.o_dbg_wr_beat_idx.value)} "
        f"perf_rd_cmd={int(dut.o_perf_rd_cmd.value)} perf_rd_beat={int(dut.o_perf_rd_beat.value)} "
        f"perf_wr_cmd={int(dut.o_perf_wr_cmd.value)} perf_wr_beat={int(dut.o_perf_wr_beat.value)}"
    )

    got = mem.load_i32_matrix(0x30000, s, d, o_stride)
    cmodel_out = cmodel.out_matrix()

    max_err = 0
    max_i = 0
    max_j = 0
    max_got = 0
    max_ref = 0
    mismatch_cnt = 0
    neg_match_cnt = 0
    got_zero_cnt = 0
    ref_zero_cnt = 0
    for i in range(s):
        for j in range(d):
            if got[i][j] == 0:
                got_zero_cnt += 1
            if ref[i][j] == 0:
                ref_zero_cnt += 1
            if got[i][j] != ref[i][j]:
                mismatch_cnt += 1
                if got[i][j] == -ref[i][j]:
                    neg_match_cnt += 1
            err = abs(got[i][j] - ref[i][j])
            if err > max_err:
                max_err = err
                max_i = i
                max_j = j
                max_got = got[i][j]
                max_ref = ref[i][j]

    cmodel_vs_rtl_max = 0
    cmodel_worst = None
    for i in range(s):
        for j in range(d):
            err = abs(got[i][j] - cmodel_out[i][j])
            if err > cmodel_vs_rtl_max:
                cmodel_vs_rtl_max = err
                cmodel_worst = (i, j, got[i][j], cmodel_out[i][j])

    rd_cmd = int(dut.o_perf_rd_cmd.value)
    rd_beat = int(dut.o_perf_rd_beat.value)
    wr_cmd = int(dut.o_perf_wr_cmd.value)
    wr_beat = int(dut.o_perf_wr_beat.value)
    comp = int(dut.o_perf_compute_cycles.value)
    soft = int(dut.o_perf_softmax_updates.value)

    num_q = s // tq
    num_k = s // tk
    q_beats = (tq * d + FP8_PER_BEAT - 1) // FP8_PER_BEAT
    kv_beats = (tk * d + FP8_PER_BEAT - 1) // FP8_PER_BEAT
    o_beats = (tq * d + I32_PER_BEAT - 1) // I32_PER_BEAT

    exp_rd_cmd = num_q + num_q * num_k * 2
    exp_rd_beat = num_q * q_beats + num_q * num_k * (kv_beats + kv_beats)
    exp_wr_cmd = num_q
    exp_wr_beat = num_q * o_beats
    exp_comp = num_q * num_k
    exp_soft = num_q * num_k * tq * tk

    dut._log.info(
        "fp8_dma_e2e: max_err=%d rd_cmd=%d rd_beat=%d wr_cmd=%d wr_beat=%d comp=%d soft=%d",
        max_err,
        rd_cmd,
        rd_beat,
        wr_cmd,
        wr_beat,
        comp,
        soft,
    )
    dut._log.info(
        "fp8_dma_e2e_maxloc: i=%d j=%d got=%d ref=%d",
        max_i,
        max_j,
        max_got,
        max_ref,
    )
    dut._log.info(
        "fp8_dma_e2e_mismatch: total=%d neg_equal=%d",
        mismatch_cnt,
        neg_match_cnt,
    )
    dut._log.info(
        "fp8_dma_e2e_zeros: got=%d ref=%d",
        got_zero_cnt,
        ref_zero_cnt,
    )
    dut._log.info(
        "fp8_dma_e2e_sample_r0: got=%s ref=%s",
        got[0][:8],
        ref[0][:8],
    )
    dut._log.info(
        "fp8_dma_e2e_sample_r31: got=%s ref=%s",
        got[31][:8],
        ref[31][:8],
    )
    dut._log.info(
        "fp8_dma_cmodel_judge: rtl_vs_cmodel_max=%d worst=%s",
        cmodel_vs_rtl_max,
        cmodel_worst,
    )
    dut._log.info(
        "fp8_dma_internal_row0_dbg: m=%d l=%d ref_m=%d ref_l=%d acc00=%d ref_acc00=%d",
        s32(int(dut.o_dbg_m0.value)),
        int(dut.o_dbg_l0.value),
        ref_m0,
        ref_l0,
        s64(int(dut.o_dbg_acc00.value)),
        ref_acc0[0],
    )

    assert max_err == 0
    assert rd_cmd == exp_rd_cmd
    assert rd_beat == exp_rd_beat
    assert wr_cmd == exp_wr_cmd
    assert wr_beat == exp_wr_beat
    assert comp == exp_comp
    assert soft == exp_soft
    assert cmodel_vs_rtl_max == 0
