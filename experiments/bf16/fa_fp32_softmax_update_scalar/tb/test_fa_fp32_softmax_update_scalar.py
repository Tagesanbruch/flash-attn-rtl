import random
import math

import cocotb
from cocotb.triggers import Timer

from bf16.common.golden_models import bf16_to_fp32_bits
from bf16.common.golden_models import bits_to_f32
from bf16.common.golden_models import f32_to_bits
from bf16.common.golden_models import online_softmax_fp32_step


def approx_equal_bits(got_bits: int, ref_bits: int, rel_tol: float = 0.03, abs_tol: float = 3e-4) -> None:
    got = bits_to_f32(got_bits)
    ref = bits_to_f32(ref_bits)
    err = abs(got - ref)
    limit = max(abs_tol, abs(ref) * rel_tol)
    assert err <= limit, f"got={got} ref={ref} err={err} limit={limit} got_bits=0x{got_bits:08x} ref_bits=0x{ref_bits:08x}"


def random_bf16_in_range(low: float, high: float) -> int:
    value = random.uniform(low, high)
    return (f32_to_bits(value) >> 16) & 0xFFFF


async def check_case(dut, row_start: int, score_bf16: int, value_bf16: int, m_old: int, l_old: int, acc_old: int):
    dut.i_row_start.value = row_start
    dut.i_score_bf16.value = score_bf16
    dut.i_value_bf16.value = value_bf16
    dut.i_m_old_fp32.value = m_old
    dut.i_l_old_fp32.value = l_old
    dut.i_acc_old_fp32.value = acc_old
    await Timer(1, units="ns")

    ref = online_softmax_fp32_step(m_old, l_old, acc_old, score_bf16, value_bf16, bool(row_start))
    got_m = int(dut.o_m_new_fp32.value) & 0xFFFFFFFF
    got_l = int(dut.o_l_new_fp32.value) & 0xFFFFFFFF
    got_acc = int(dut.o_acc_new_fp32.value) & 0xFFFFFFFF
    got_inv = int(dut.o_inv_l_new_fp32.value) & 0xFFFFFFFF
    got_exp_old = int(dut.o_exp_old_fp32.value) & 0xFFFFFFFF
    got_exp_new = int(dut.o_exp_new_fp32.value) & 0xFFFFFFFF
    ctx = (
        f"row_start={row_start} score=0x{score_bf16:04x} value=0x{value_bf16:04x} "
        f"m_old=0x{m_old:08x} l_old=0x{l_old:08x} acc_old=0x{acc_old:08x}"
    )

    assert got_m == ref["m_new_bits"], f"m mismatch got=0x{got_m:08x} ref=0x{ref['m_new_bits']:08x} {ctx}"
    approx_equal_bits(got_exp_old, ref["exp_old_bits"], rel_tol=0.05, abs_tol=1e-3)
    approx_equal_bits(got_exp_new, ref["exp_new_bits"], rel_tol=0.05, abs_tol=1e-3)
    approx_equal_bits(got_l, ref["l_new_bits"], rel_tol=0.08, abs_tol=4e-3)
    approx_equal_bits(got_acc, ref["acc_new_bits"], rel_tol=0.12, abs_tol=4e-3)

    ref_inv = 0.0 if bits_to_f32(ref["l_new_bits"]) == 0.0 else 1.0 / bits_to_f32(ref["l_new_bits"])
    approx_equal_bits(got_inv, f32_to_bits(ref_inv), rel_tol=0.12, abs_tol=5e-3)

    return {
        "exp_old_ae": abs(bits_to_f32(got_exp_old) - bits_to_f32(ref["exp_old_bits"])),
        "exp_new_ae": abs(bits_to_f32(got_exp_new) - bits_to_f32(ref["exp_new_bits"])),
        "l_ae": abs(bits_to_f32(got_l) - bits_to_f32(ref["l_new_bits"])),
        "acc_ae": abs(bits_to_f32(got_acc) - bits_to_f32(ref["acc_new_bits"])),
        "inv_ae": abs(bits_to_f32(got_inv) - ref_inv),
    }


@cocotb.test()
async def test_fp32_softmax_update_scalar_directed(dut):
    vectors = [
        (1, 0x3F80, 0x3F80, 0, 0, 0),
        (0, 0x4000, 0x3F80, 0x3F800000, 0x3F800000, 0x3F800000),
        (0, 0x3F00, 0x4000, 0x40000000, 0x3FC00000, 0x3F800000),
        (0, 0xBF80, 0x3F80, 0x3F800000, 0x3F800000, 0x3F800000),
    ]
    for vector in vectors:
        await check_case(dut, *vector)


@cocotb.test()
async def test_fp32_softmax_update_scalar_random(dut):
    random.seed(20260312)
    metrics = {"exp_old_ae": [], "exp_new_ae": [], "l_ae": [], "acc_ae": [], "inv_ae": []}
    for _ in range(3000):
        row_start = 1 if random.random() < 0.1 else 0
        score_bf16 = random_bf16_in_range(-8.0, 8.0)
        value_bf16 = random_bf16_in_range(-4.0, 4.0)
        if row_start:
            m_old = 0
            l_old = 0
            acc_old = 0
        else:
            m_old = f32_to_bits(random.uniform(-8.0, 8.0))
            l_old = f32_to_bits(random.uniform(0.0, 8.0))
            acc_old = f32_to_bits(random.uniform(-8.0, 8.0))
        stat = await check_case(dut, row_start, score_bf16, value_bf16, m_old, l_old, acc_old)
        for key in metrics:
            value = stat[key]
            if math.isfinite(value):
                metrics[key].append(value)

    for key, arr in metrics.items():
        mae = (sum(arr) / len(arr)) if arr else 0.0
        maxae = max(arr) if arr else 0.0
        dut._log.info("softmax_update_scalar_%s: samples=%d MAE=%.6f MaxAE=%.6f", key, len(arr), mae, maxae)
