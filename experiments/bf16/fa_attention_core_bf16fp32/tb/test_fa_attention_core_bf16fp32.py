import math
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from bf16.common.golden_models import (
    attention_bf16_fp32_reference,
    calc_abs_error_stats,
    f32_to_bits,
    fp32_to_bf16_bits,
)


BUS_W = 128
ELEMS_PER_BEAT = BUS_W // 16
BYTES_PER_BEAT = BUS_W // 8

Q_BASE = 0x0000
K_BASE = 0x4000
V_BASE = 0x8000
O_BASE = 0xC000


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
    cycles = int(dut.o_cycles.value)
    dut._log.info(
        f"causal={causal} cycles={cycles} expected_cycles={expected_cycles} ref_cycle_model={ref['cycle_model']} "
        f"mae={stats['mae']:.6f} maxe={stats['maxe']:.6f}"
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
