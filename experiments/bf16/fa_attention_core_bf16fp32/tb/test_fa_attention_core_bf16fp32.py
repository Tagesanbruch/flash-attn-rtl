import math
import os
import random
import csv
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from bf16.common.golden_models import (
    attention_bf16_fp32_reference,
    bits_to_f32,
    calc_abs_error_stats,
    f32_to_bits,
    fp32_to_bf16_bits,
    online_softmax_fp32_step,
)
from bf16.common.cmodel_ref import fp32_add, fp32_mul_q16, fp32_recip


BUS_W = 128
ELEMS_PER_BEAT = BUS_W // 16
BYTES_PER_BEAT = BUS_W // 8

Q_BASE = 0x0000_0000
K_BASE = 0x0010_0000
V_BASE = 0x0020_0000
O_BASE = 0x0030_0000


def expected_cycles_mvp(seq_len: int, d: int, tq: int, tk: int) -> int:
    num_q_tiles = seq_len // tq
    num_k_tiles = seq_len // tk
    beats_q = (tq * d) // ELEMS_PER_BEAT
    beats_kv = (tk * d) // ELEMS_PER_BEAT
    cycles_per_pair = 2 * d + 2
    cycles_per_q_tile = (
        (beats_q + 1)
        + 1
        + num_k_tiles * ((beats_kv + 1) + (beats_kv + 1) + tq * tk * cycles_per_pair)
        + tq * d
        + (beats_q + 1)
        + 1
    )
    return num_q_tiles * cycles_per_q_tile + 1


def resolve_param(dut, name: str, default: int) -> int:
    env_key = f"PARAM_{name}"
    env_val = os.environ.get(env_key)
    if env_val is not None:
        return int(env_val)
    try:
        return int(getattr(dut, name).value)
    except AttributeError:
        return default


def assert_non_overlapping_regions(seq_len: int, d: int, stride_bytes: int) -> None:
    matrix_bytes = seq_len * stride_bytes
    regions = [
        ("Q", Q_BASE, Q_BASE + matrix_bytes),
        ("K", K_BASE, K_BASE + matrix_bytes),
        ("V", V_BASE, V_BASE + matrix_bytes),
        ("O", O_BASE, O_BASE + matrix_bytes),
    ]
    for i in range(len(regions)):
        n0, s0, e0 = regions[i]
        for j in range(i + 1, len(regions)):
            n1, s1, e1 = regions[j]
            if not (e0 <= s1 or e1 <= s0):
                raise AssertionError(
                    f"DMA region overlap: {n0}[0x{s0:08x},0x{e0:08x}) vs {n1}[0x{s1:08x},0x{e1:08x})"
                )


class DmaMemory:
    def __init__(self):
        self.mem: dict[int, int] = {}

    def store_matrix_bf16(self, base_addr: int, matrix: list[list[int]], stride_bytes: int) -> None:
        for r, row in enumerate(matrix):
            row_addr = base_addr + r * stride_bytes
            for beat in range(len(row) // ELEMS_PER_BEAT):
                pack = 0
                for e in range(ELEMS_PER_BEAT):
                    pack |= (row[beat * ELEMS_PER_BEAT + e] & 0xFFFF) << (16 * e)
                self.mem[row_addr + beat * BYTES_PER_BEAT] = pack

    def load_matrix_bf16(self, base_addr: int, rows: int, cols: int, stride_bytes: int) -> list[list[int]]:
        out = []
        for r in range(rows):
            row_addr = base_addr + r * stride_bytes
            row = []
            for beat in range(cols // ELEMS_PER_BEAT):
                pack = self.mem.get(row_addr + beat * BYTES_PER_BEAT, 0)
                for e in range(ELEMS_PER_BEAT):
                    row.append((pack >> (16 * e)) & 0xFFFF)
            out.append(row)
        return out

    def read_burst(self, start_addr: int, beats: int) -> list[int]:
        return [self.mem.get(start_addr + i * BYTES_PER_BEAT, 0) for i in range(beats)]


def rand_bf16(low: float, high: float) -> int:
    return fp32_to_bf16_bits(f32_to_bits(random.uniform(low, high)))


async def dma_read_driver(dut, mem: DmaMemory) -> None:
    dut.dma_rd_cmd_ready.value = 1
    dut.dma_rd_data_valid.value = 0
    dut.dma_rd_data.value = 0
    dut.dma_rd_data_last.value = 0
    while True:
        await RisingEdge(dut.clk)
        if int(dut.dma_rd_cmd_valid.value) and int(dut.dma_rd_cmd_ready.value):
            addr = int(dut.dma_rd_cmd_addr.value)
            beats = int(dut.dma_rd_cmd_len.value) + 1
            data = mem.read_burst(addr, beats)
            dut.dma_rd_cmd_ready.value = 0
            for idx, beat in enumerate(data):
                dut.dma_rd_data_valid.value = 1
                dut.dma_rd_data.value = beat
                dut.dma_rd_data_last.value = 1 if idx == beats - 1 else 0
                while True:
                    await RisingEdge(dut.clk)
                    if int(dut.dma_rd_data_ready.value):
                        break
            dut.dma_rd_data_valid.value = 0
            dut.dma_rd_data_last.value = 0
            dut.dma_rd_cmd_ready.value = 1


async def dma_write_driver(dut, mem: DmaMemory) -> None:
    dut.dma_wr_cmd_ready.value = 1
    dut.dma_wr_data_ready.value = 0
    while True:
        await RisingEdge(dut.clk)
        if int(dut.dma_wr_cmd_valid.value) and int(dut.dma_wr_cmd_ready.value):
            addr = int(dut.dma_wr_cmd_addr.value)
            beats = int(dut.dma_wr_cmd_len.value) + 1
            dut.dma_wr_cmd_ready.value = 0
            for idx in range(beats):
                dut.dma_wr_data_ready.value = 1
                while True:
                    await RisingEdge(dut.clk)
                    if int(dut.dma_wr_data_valid.value) and int(dut.dma_wr_data_ready.value):
                        mem.mem[addr + idx * BYTES_PER_BEAT] = int(dut.dma_wr_data.value)
                        break
            dut.dma_wr_data_ready.value = 0
            dut.dma_wr_cmd_ready.value = 1


async def reset_dut(dut) -> None:
    dut.rst_n.value = 0
    dut.i_start.value = 0
    dut.i_soft_reset.value = 0
    dut.i_causal_en.value = 0
    dut.i_scale_fp32.value = 0
    dut.i_neg_large_fp32.value = 0
    dut.i_q_base.value = Q_BASE
    dut.i_k_base.value = K_BASE
    dut.i_v_base.value = V_BASE
    dut.i_o_base.value = O_BASE
    dut.i_stride_bytes.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_case(dut, causal: bool, seed: int) -> None:
    seq_len = resolve_param(dut, "SEQ_LEN", 256)
    d = resolve_param(dut, "D", 64)
    tq = resolve_param(dut, "TQ", 32)
    tk = resolve_param(dut, "TK", 64)
    stride_bytes = d * 2
    assert_non_overlapping_regions(seq_len, d, stride_bytes)
    random.seed(seed)
    dut._log.info(
        f"params: SEQ_LEN={seq_len} D={d} TQ={tq} TK={tk} BUS_W={BUS_W}"
    )
    q_mat = [[rand_bf16(-1.0, 1.0) for _ in range(d)] for _ in range(seq_len)]
    k_mat = [[rand_bf16(-1.0, 1.0) for _ in range(d)] for _ in range(seq_len)]
    v_mat = [[rand_bf16(-1.0, 1.0) for _ in range(d)] for _ in range(seq_len)]

    scale_bits = f32_to_bits(1.0 / math.sqrt(d))
    neg_large_bits = f32_to_bits(-64.0)

    mem = DmaMemory()
    mem.store_matrix_bf16(Q_BASE, q_mat, stride_bytes)
    mem.store_matrix_bf16(K_BASE, k_mat, stride_bytes)
    mem.store_matrix_bf16(V_BASE, v_mat, stride_bytes)

    cocotb.start_soon(dma_read_driver(dut, mem))
    cocotb.start_soon(dma_write_driver(dut, mem))

    dut.i_causal_en.value = 1 if causal else 0
    dut.i_scale_fp32.value = scale_bits
    dut.i_neg_large_fp32.value = neg_large_bits
    dut.i_stride_bytes.value = stride_bytes
    dut.i_start.value = 1
    await RisingEdge(dut.clk)
    dut.i_start.value = 0

    expected_cycles = expected_cycles_mvp(seq_len, d, tq, tk)
    max_cycles_cfg = int(os.environ.get("CORE_MAX_CYCLES", "400000"))
    timeout_cycles = min(max_cycles_cfg, max(1000, expected_cycles * 4))
    perf = {
        "load_q": 0,
        "init_context": 0,
        "load_k": 0,
        "load_v": 0,
        "compute": 0,
        "normalize": 0,
        "write_o": 0,
        "next_q": 0,
        "dp_run": 0,
        "score_done": 0,
        "softmax_prep": 0,
        "comp_launch": 0,
        "norm_recip_req": 0,
        "norm_recip_rsp": 0,
    }
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.o_busy.value):
            perf["load_q"] += int(dut.o_perf_ms_load_q.value)
            perf["init_context"] += int(dut.o_perf_ms_init_context.value)
            perf["load_k"] += int(dut.o_perf_ms_load_k.value)
            perf["load_v"] += int(dut.o_perf_ms_load_v.value)
            perf["compute"] += int(dut.o_perf_ms_compute.value)
            perf["normalize"] += int(dut.o_perf_ms_normalize.value)
            perf["write_o"] += int(dut.o_perf_ms_write_o.value)
            perf["next_q"] += int(dut.o_perf_ms_next_q.value)
            perf["dp_run"] += int(dut.o_perf_cs_dp_run.value)
            perf["score_done"] += int(dut.o_perf_cs_score_done.value)
            perf["softmax_prep"] += int(dut.o_perf_cs_softmax_prep.value)
            perf["comp_launch"] += int(dut.o_perf_comp_launch.value)
            perf["norm_recip_req"] += int(dut.o_perf_norm_recip_req.value)
            perf["norm_recip_rsp"] += int(dut.o_perf_norm_recip_rsp.value)
        if int(dut.o_done.value):
            break
    else:
        raise AssertionError(f"attention core timeout after {timeout_cycles} cycles")

    got_o = mem.load_matrix_bf16(O_BASE, seq_len, d, stride_bytes)
    ref = attention_bf16_fp32_reference(
        q_mat_bf16=q_mat,
        k_mat_bf16=k_mat,
        v_mat_bf16=v_mat,
        scale_bits=scale_bits,
        neg_large_bits=neg_large_bits,
        causal=causal,
        bitaccurate=True,
    )
    ref_o = ref["o_bf16"]

    flat_ref_fp32 = []
    flat_got_fp32 = []
    for i in range(seq_len):
        for j in range(d):
            got_bits = (got_o[i][j] & 0xFFFF) << 16
            ref_bits = (ref_o[i][j] & 0xFFFF) << 16
            flat_got_fp32.append(got_bits)
            flat_ref_fp32.append(ref_bits)

    stats = calc_abs_error_stats(flat_ref_fp32, flat_got_fp32)
    worst = {"ae": -1.0, "i": 0, "j": 0, "got": 0, "ref": 0}
    rows = []
    for i in range(seq_len):
        for j in range(d):
            idx = i * d + j
            got_bits = flat_got_fp32[idx]
            ref_bits = flat_ref_fp32[idx]
            got_f = bits_to_f32(got_bits)
            ref_f = bits_to_f32(ref_bits)
            ae = abs(got_f - ref_f)
            if ae > worst["ae"]:
                worst = {"ae": ae, "i": i, "j": j, "got": got_bits, "ref": ref_bits}
            rows.append(
                {
                    "i": i,
                    "j": j,
                    "got_bf16": f"0x{got_o[i][j]:04x}",
                    "ref_bf16": f"0x{ref_o[i][j]:04x}",
                    "got_fp32_bits": f"0x{got_bits:08x}",
                    "ref_fp32_bits": f"0x{ref_bits:08x}",
                    "got_fp32": got_f,
                    "ref_fp32": ref_f,
                    "ae": ae,
                }
            )

    if os.environ.get("CORE_AE_DUMP", "1") not in {"0", "false", "False"}:
        out_dir = Path(os.environ.get("CORE_AE_LOG_DIR", "logs/bf16_module_ae")).resolve()
        out_dir.mkdir(parents=True, exist_ok=True)
        out_csv = out_dir / f"fa_attention_core_bf16fp32_seed{seed}_{'causal' if causal else 'noncausal'}.csv"
        with out_csv.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
        dut._log.info("core_detail_csv=%s", out_csv)

    cycles = int(dut.o_cycles.value)
    dut._log.info(
        f"causal={causal} cycles={cycles} expected_cycles={expected_cycles} ref_cycle_model={ref['cycle_model']} "
        f"MAE={stats['mae']:.6f} MaxAE={stats['maxe']:.6f}"
    )
    dut._log.info(
        f"worst_point: i={worst['i']} j={worst['j']} ae={worst['ae']:.6f} got=0x{worst['got']:08x} ref=0x{worst['ref']:08x}"
    )
    dut._log.info(
        "perf cycles: "
        f"load_q={perf['load_q']} init={perf['init_context']} load_k={perf['load_k']} load_v={perf['load_v']} "
        f"compute={perf['compute']} norm={perf['normalize']} write_o={perf['write_o']} next_q={perf['next_q']}"
    )
    dut._log.info(
        "perf compute: "
        f"dp_run={perf['dp_run']} score_done={perf['score_done']} softmax_prep={perf['softmax_prep']} "
        f"comp_launch={perf['comp_launch']} recip_req={perf['norm_recip_req']} recip_rsp={perf['norm_recip_rsp']}"
    )

    assert int(dut.o_error.value) == 0
    if int(os.environ.get("CORE_STRICT_CYCLES", "1")):
        assert cycles == expected_cycles, f"unexpected cycle count: got={cycles} exp={expected_cycles}"
    assert stats["mae"] <= 2.5e-4, f"mae too large: {stats['mae']}"
    assert stats["maxe"] <= 4.5e-3, f"maxe too large: {stats['maxe']}"


def score_bf16_ref_for_pair(
    q_mat: list[list[int]],
    k_mat: list[list[int]],
    q_idx: int,
    k_idx: int,
    d: int,
    scale_bits: int,
    causal: bool,
    neg_large_bits: int,
) -> int:
    score_bits = 0
    for kk in range(d):
        prod_bits = fp32_mul_q16((q_mat[q_idx][kk] & 0xFFFF) << 16, (k_mat[k_idx][kk] & 0xFFFF) << 16)
        score_bits = fp32_add(score_bits, prod_bits)
    score_bits = fp32_mul_q16(score_bits, scale_bits)
    if causal and k_idx > q_idx:
        score_bits = neg_large_bits
    return fp32_to_bf16_bits(score_bits)


@cocotb.test()
async def test_attention_core_trace_first_divergence(dut):
    if os.environ.get("CORE_TRACE_ENABLE", "0") != "1":
        dut._log.info("trace test skipped (set CORE_TRACE_ENABLE=1 to enable)")
        return

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    seq_len = resolve_param(dut, "SEQ_LEN", 256)
    d = resolve_param(dut, "D", 64)
    tq = resolve_param(dut, "TQ", 32)
    tk = resolve_param(dut, "TK", 64)
    stride_bytes = d * 2
    assert_non_overlapping_regions(seq_len, d, stride_bytes)
    seed = int(os.environ.get("CORE_TRACE_SEED", "20260312"))
    causal = bool(int(os.environ.get("CORE_TRACE_CAUSAL", "0")))

    random.seed(seed)
    q_mat = [[rand_bf16(-1.0, 1.0) for _ in range(d)] for _ in range(seq_len)]
    k_mat = [[rand_bf16(-1.0, 1.0) for _ in range(d)] for _ in range(seq_len)]
    v_mat = [[rand_bf16(-1.0, 1.0) for _ in range(d)] for _ in range(seq_len)]

    scale_bits = f32_to_bits(1.0 / math.sqrt(d))
    neg_large_bits = f32_to_bits(-64.0)

    mem = DmaMemory()
    mem.store_matrix_bf16(Q_BASE, q_mat, stride_bytes)
    mem.store_matrix_bf16(K_BASE, k_mat, stride_bytes)
    mem.store_matrix_bf16(V_BASE, v_mat, stride_bytes)

    cocotb.start_soon(dma_read_driver(dut, mem))
    cocotb.start_soon(dma_write_driver(dut, mem))

    dut.i_causal_en.value = 1 if causal else 0
    dut.i_scale_fp32.value = scale_bits
    dut.i_neg_large_fp32.value = neg_large_bits
    dut.i_stride_bytes.value = stride_bytes
    dut.i_start.value = 1
    await RisingEdge(dut.clk)
    dut.i_start.value = 0

    num_q_tiles = seq_len // tq
    num_k_tiles = seq_len // tk
    ref_m = [0 for _ in range(seq_len)]
    ref_l = [0 for _ in range(seq_len)]

    q_tile_idx = 0
    k_tile_idx = 0
    qi = 0
    kj = 0

    first_div = None
    first_score_div = None
    first_index_div = None
    max_l_ae = 0.0
    max_m_ae = 0.0
    max_inv_ae = 0.0
    max_score_ae = 0.0
    traced_pairs = 0

    expected_cycles = expected_cycles_mvp(seq_len, d, tq, tk)
    timeout_cycles = min(int(os.environ.get("CORE_MAX_CYCLES", "9000000")), max(1000, expected_cycles * 4))

    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.o_perf_norm_recip_req.value):
            dut_q_tile = int(dut.q_tile_idx.value)
            dut_k_tile = int(dut.k_tile_idx.value)
            dut_qi = int(dut.qi.value)
            dut_kj = int(dut.kj.value)
            if first_index_div is None and (dut_q_tile != q_tile_idx or dut_k_tile != k_tile_idx or dut_qi != qi or dut_kj != kj):
                first_index_div = {
                    "dut_q_tile": dut_q_tile,
                    "dut_k_tile": dut_k_tile,
                    "dut_qi": dut_qi,
                    "dut_kj": dut_kj,
                    "sw_q_tile": q_tile_idx,
                    "sw_k_tile": k_tile_idx,
                    "sw_qi": qi,
                    "sw_kj": kj,
                }

            q_global = q_tile_idx * tq + qi
            k_global = k_tile_idx * tk + kj
            row_start = (k_tile_idx == 0 and kj == 0)

            score_bf16 = score_bf16_ref_for_pair(
                q_mat=q_mat,
                k_mat=k_mat,
                q_idx=q_global,
                k_idx=k_global,
                d=d,
                scale_bits=scale_bits,
                causal=causal,
                neg_large_bits=neg_large_bits,
            )
            ref = online_softmax_fp32_step(
                m_old_bits=ref_m[q_global],
                l_old_bits=ref_l[q_global],
                acc_old_bits=0,
                score_bf16=score_bf16,
                value_bf16=0,
                row_start=row_start,
                bitaccurate=True,
            )
            ref_m[q_global] = ref["m_new_bits"]
            ref_l[q_global] = ref["l_new_bits"]
            ref_inv = 0 if bits_to_f32(ref["l_new_bits"]) == 0.0 else fp32_recip(ref["l_new_bits"])

            got_m = int(dut.m_new_fp32.value) & 0xFFFFFFFF
            got_l = int(dut.l_new_fp32.value) & 0xFFFFFFFF
            got_inv = int(dut.inv_l_new_fp32.value) & 0xFFFFFFFF
            got_score_bf16 = int(dut.score_bf16.value) & 0xFFFF

            score_ae = abs(bits_to_f32((got_score_bf16 & 0xFFFF) << 16) - bits_to_f32((score_bf16 & 0xFFFF) << 16))
            max_score_ae = max(max_score_ae, score_ae)
            if first_score_div is None and got_score_bf16 != score_bf16:
                first_score_div = {
                    "q": q_global,
                    "k": k_global,
                    "got": got_score_bf16,
                    "ref": score_bf16,
                    "ae": score_ae,
                }

            m_ae = abs(bits_to_f32(got_m) - bits_to_f32(ref["m_new_bits"]))
            l_ae = abs(bits_to_f32(got_l) - bits_to_f32(ref["l_new_bits"]))
            inv_ae = abs(bits_to_f32(got_inv) - bits_to_f32(ref_inv))
            max_m_ae = max(max_m_ae, m_ae)
            max_l_ae = max(max_l_ae, l_ae)
            max_inv_ae = max(max_inv_ae, inv_ae)
            traced_pairs += 1

            if first_div is None and (l_ae > 0.01 or m_ae > 0.01 or inv_ae > 0.01):
                first_div = {
                    "q": q_global,
                    "k": k_global,
                    "m_ae": m_ae,
                    "l_ae": l_ae,
                    "inv_ae": inv_ae,
                    "got_m": got_m,
                    "ref_m": ref["m_new_bits"],
                    "got_l": got_l,
                    "ref_l": ref["l_new_bits"],
                    "got_inv": got_inv,
                    "ref_inv": ref_inv,
                }

            kj += 1
            if kj == tk:
                kj = 0
                qi += 1
                if qi == tq:
                    qi = 0
                    k_tile_idx += 1
                    if k_tile_idx == num_k_tiles:
                        k_tile_idx = 0
                        q_tile_idx += 1
                        if q_tile_idx == num_q_tiles:
                            q_tile_idx = 0

        if int(dut.o_done.value):
            break
    else:
        raise AssertionError(f"trace timeout after {timeout_cycles} cycles")

    dut._log.info(
        "trace_summary: seed=%d causal=%d traced_pairs=%d max_score_ae=%.6f max_m_ae=%.6f max_l_ae=%.6f max_inv_ae=%.6f",
        seed,
        int(causal),
        traced_pairs,
        max_score_ae,
        max_m_ae,
        max_l_ae,
        max_inv_ae,
    )
    if first_score_div is None:
        dut._log.info("trace_first_score_divergence: none (bf16 bits identical)")
    else:
        dut._log.info(
            "trace_first_score_divergence: q=%d k=%d ae=%.6f got=0x%04x ref=0x%04x",
            first_score_div["q"],
            first_score_div["k"],
            first_score_div["ae"],
            first_score_div["got"],
            first_score_div["ref"],
        )
    if first_index_div is None:
        dut._log.info("trace_index_alignment: pass")
    else:
        dut._log.info(
            "trace_index_alignment: first_mismatch dut=(qt=%d,kt=%d,qi=%d,kj=%d) sw=(qt=%d,kt=%d,qi=%d,kj=%d)",
            first_index_div["dut_q_tile"],
            first_index_div["dut_k_tile"],
            first_index_div["dut_qi"],
            first_index_div["dut_kj"],
            first_index_div["sw_q_tile"],
            first_index_div["sw_k_tile"],
            first_index_div["sw_qi"],
            first_index_div["sw_kj"],
        )
    if first_div is None:
        dut._log.info("trace_first_divergence: none (threshold=0.01)")
    else:
        dut._log.info(
            "trace_first_divergence: q=%d k=%d m_ae=%.6f l_ae=%.6f inv_ae=%.6f got_l=0x%08x ref_l=0x%08x",
            first_div["q"],
            first_div["k"],
            first_div["m_ae"],
            first_div["l_ae"],
            first_div["inv_ae"],
            first_div["got_l"],
            first_div["ref_l"],
        )


@cocotb.test()
async def test_attention_core_noncausal(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)
    await run_case(dut, causal=False, seed=20260312)


@cocotb.test()
async def test_attention_core_causal(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)
    await run_case(dut, causal=True, seed=20260313)
