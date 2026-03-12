import ctypes
import math
import struct
from typing import Iterable


def bits_to_f32(bits: int) -> float:
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


def f32_to_bits(value: float) -> int:
    return struct.unpack('>I', struct.pack('>f', ctypes.c_float(value).value))[0]


def f32(value: float) -> float:
    return ctypes.c_float(value).value


def bf16_to_fp32_bits(x: int) -> int:
    return (x & 0xFFFF) << 16


def fp32_to_bf16_bits(x: int) -> int:
    sign = (x >> 31) & 0x1
    exp = (x >> 23) & 0xFF
    frac = x & 0x7FFFFF
    if exp == 0xFF and frac != 0:
        payload = (frac >> 16) & 0x7F
        if payload == 0:
            payload = 0x40
        return (sign << 15) | (0xFF << 7) | payload
    rounded = (x + 0x7FFF + ((x >> 16) & 1)) & 0xFFFFFFFF
    return (rounded >> 16) & 0xFFFF


def bf16_roundtrip_fp32_bits(x: int) -> int:
    return bf16_to_fp32_bits(fp32_to_bf16_bits(x))


def canonicalize_add(a_bits: int, b_bits: int, raw_bits: int) -> int:
    a_exp = (a_bits >> 23) & 0xFF
    a_frac = a_bits & 0x7FFFFF
    b_exp = (b_bits >> 23) & 0xFF
    b_frac = b_bits & 0x7FFFFF
    a_is_nan = a_exp == 0xFF and a_frac != 0
    b_is_nan = b_exp == 0xFF and b_frac != 0
    a_is_inf = a_exp == 0xFF and a_frac == 0
    b_is_inf = b_exp == 0xFF and b_frac == 0
    a_sign = (a_bits >> 31) & 0x1
    b_sign = (b_bits >> 31) & 0x1
    if a_is_nan or b_is_nan or (a_is_inf and b_is_inf and a_sign != b_sign):
        return 0x7FC00000
    return raw_bits & 0xFFFFFFFF


def fp32_add_bits(a_bits: int, b_bits: int) -> int:
    raw = f32_to_bits(f32(bits_to_f32(a_bits) + bits_to_f32(b_bits)))
    return canonicalize_add(a_bits, b_bits, raw)


def bf16_mul_fp32_bits(a_bf16: int, b_bf16: int) -> int:
    a_bits = bf16_to_fp32_bits(a_bf16)
    b_bits = bf16_to_fp32_bits(b_bf16)
    prod_bits = f32_to_bits(f32(bits_to_f32(a_bits) * bits_to_f32(b_bits)))
    exp = (prod_bits >> 23) & 0xFF
    frac = prod_bits & 0x7FFFFF
    if exp == 0xFF and frac != 0:
        sign = ((a_bf16 >> 15) ^ (b_bf16 >> 15)) & 0x1
        prod_bits = (sign << 31) | 0x7FC00000
    return prod_bits


def bf16_mul_reference(a_bf16: int, b_bf16: int) -> tuple[int, int]:
    prod_bits = bf16_mul_fp32_bits(a_bf16, b_bf16)
    return prod_bits, fp32_to_bf16_bits(prod_bits)


def dotprod_fp32_reference(a_vec_bf16: Iterable[int], b_vec_bf16: Iterable[int]) -> dict[str, list[int]]:
    mul_fp32 = []
    acc_fp32 = []
    acc_bits = 0
    for a_bf16, b_bf16 in zip(a_vec_bf16, b_vec_bf16):
        prod_bits = bf16_mul_fp32_bits(a_bf16, b_bf16)
        acc_bits = fp32_add_bits(acc_bits, prod_bits)
        mul_fp32.append(prod_bits)
        acc_fp32.append(acc_bits)
    return {"mul_fp32": mul_fp32, "acc_fp32": acc_fp32}


def dotprod_mixed_reference(a_vec_bf16: Iterable[int], b_vec_bf16: Iterable[int]) -> dict[str, list[int]]:
    mul_fp32 = []
    acc_fp32 = []
    acc_stage_fp32 = []
    acc_stage_bf16 = []
    acc_bits = 0
    for a_bf16, b_bf16 in zip(a_vec_bf16, b_vec_bf16):
        prod_bits = bf16_mul_fp32_bits(a_bf16, b_bf16)
        acc_bits = fp32_add_bits(acc_bits, prod_bits)
        stage_bf16 = fp32_to_bf16_bits(acc_bits)
        stage_fp32 = bf16_to_fp32_bits(stage_bf16)
        mul_fp32.append(prod_bits)
        acc_fp32.append(acc_bits)
        acc_stage_bf16.append(stage_bf16)
        acc_stage_fp32.append(stage_fp32)
    return {
        "mul_fp32": mul_fp32,
        "acc_fp32": acc_fp32,
        "acc_stage_bf16": acc_stage_bf16,
        "acc_stage_fp32": acc_stage_fp32,
    }


def _pow2_bits(delta_bits: int) -> int:
    delta = bits_to_f32(delta_bits)
    return f32_to_bits(f32(2.0 ** delta))


def online_softmax_fp32_step(
    m_old_bits: int,
    l_old_bits: int,
    acc_old_bits: int,
    score_bf16: int,
    value_bf16: int,
    row_start: bool,
) -> dict[str, int]:
    score_bits = bf16_to_fp32_bits(score_bf16)
    value_bits = bf16_to_fp32_bits(value_bf16)

    if row_start:
        m_new_bits = score_bits
        exp_old_bits = 0
    else:
        m_old = bits_to_f32(m_old_bits)
        score = bits_to_f32(score_bits)
        m_new_bits = score_bits if score > m_old else m_old_bits
        exp_old_bits = _pow2_bits(fp32_add_bits(m_old_bits, f32_to_bits(-bits_to_f32(m_new_bits))))

    exp_new_bits = _pow2_bits(fp32_add_bits(score_bits, f32_to_bits(-bits_to_f32(m_new_bits))))
    l_scaled_bits = 0 if row_start else f32_to_bits(f32(bits_to_f32(l_old_bits) * bits_to_f32(exp_old_bits)))
    l_new_bits = fp32_add_bits(l_scaled_bits, exp_new_bits)

    acc_scaled_bits = 0 if row_start else f32_to_bits(f32(bits_to_f32(acc_old_bits) * bits_to_f32(exp_old_bits)))
    v_term_bits = f32_to_bits(f32(bits_to_f32(exp_new_bits) * bits_to_f32(value_bits)))
    acc_new_bits = fp32_add_bits(acc_scaled_bits, v_term_bits)

    return {
        "m_new_bits": m_new_bits,
        "l_new_bits": l_new_bits,
        "acc_new_bits": acc_new_bits,
        "exp_old_bits": exp_old_bits,
        "exp_new_bits": exp_new_bits,
    }


def online_softmax_mixed_step(
    m_old_bits: int,
    l_old_bits: int,
    acc_old_bits: int,
    score_bf16: int,
    value_bf16: int,
    row_start: bool,
) -> dict[str, int]:
    fp32_state = online_softmax_fp32_step(
        m_old_bits=m_old_bits,
        l_old_bits=l_old_bits,
        acc_old_bits=acc_old_bits,
        score_bf16=score_bf16,
        value_bf16=value_bf16,
        row_start=row_start,
    )
    m_bf16 = fp32_to_bf16_bits(fp32_state["m_new_bits"])
    l_bf16 = fp32_to_bf16_bits(fp32_state["l_new_bits"])
    acc_bf16 = fp32_to_bf16_bits(fp32_state["acc_new_bits"])
    return {
        **fp32_state,
        "m_stage_bf16": m_bf16,
        "l_stage_bf16": l_bf16,
        "acc_stage_bf16": acc_bf16,
        "m_stage_fp32": bf16_to_fp32_bits(m_bf16),
        "l_stage_fp32": bf16_to_fp32_bits(l_bf16),
        "acc_stage_fp32": bf16_to_fp32_bits(acc_bf16),
    }


def calc_abs_error_stats(ref_bits_seq: Iterable[int], test_bits_seq: Iterable[int]) -> dict[str, float]:
    errs = []
    skipped = 0
    for a, b in zip(ref_bits_seq, test_bits_seq):
        a_f = bits_to_f32(a)
        b_f = bits_to_f32(b)
        if not (math.isfinite(a_f) and math.isfinite(b_f)):
            skipped += 1
            continue
        errs.append(abs(a_f - b_f))

    if not errs:
        return {"mae": 0.0, "maxe": 0.0, "count": 0.0, "skipped": float(skipped)}
    return {
        "mae": sum(errs) / len(errs),
        "maxe": max(errs),
        "count": float(len(errs)),
        "skipped": float(skipped),
    }
