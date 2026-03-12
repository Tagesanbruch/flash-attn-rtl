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


def _round_shift_right_rne_u32(value: int, shamt: int) -> int:
    value &= 0xFFFFFFFF
    if shamt <= 0:
        return value
    if shamt >= 32:
        return 1 if value != 0 else 0
    base = value >> shamt
    guard = (value >> (shamt - 1)) & 0x1
    sticky_mask = (1 << (shamt - 1)) - 1 if shamt > 1 else 0
    sticky = 1 if (value & sticky_mask) != 0 else 0
    if guard and (sticky or (base & 0x1)):
        return (base + 1) & 0xFFFFFFFF
    return base & 0xFFFFFFFF


def _fp32_to_q16_16_signed(bits: int) -> int:
    sign = (bits >> 31) & 0x1
    exp = (bits >> 23) & 0xFF
    frac = bits & 0x7FFFFF
    if exp == 0 and frac == 0:
        return 0
    sig24 = frac if exp == 0 else ((1 << 23) | frac)
    exp_unbiased = -126 if exp == 0 else exp - 127
    shift_i = exp_unbiased - 7
    if shift_i >= 0:
        mag = sig24 << shift_i
        mag = min(mag, 0x7FFFFFFF)
    else:
        mag = _round_shift_right_rne_u32(sig24, -shift_i)
    mag = min(mag, 0x7FFFFFFF)
    return -mag if sign else mag


def _q16_16_signed_to_fp32_bits(q_val: int) -> int:
    sign = 1 if q_val < 0 else 0
    mag = -q_val if q_val < 0 else q_val
    mag &= 0xFFFFFFFFFFFFFFFF
    if mag == 0:
        return sign << 31
    msb_idx = mag.bit_length() - 1
    exp_unbiased = msb_idx - 16
    shift_i = msb_idx - 23
    if shift_i > 0:
        sig24 = _round_shift_right_rne_u32(mag & 0xFFFFFFFF, shift_i)
    else:
        sig24 = (mag << (23 - msb_idx)) & 0xFFFFFFFFFFFFFFFF
    if sig24 & (1 << 24):
        sig24 >>= 1
        exp_unbiased += 1
    if exp_unbiased > 127:
        return (sign << 31) | 0x7F800000
    exp = exp_unbiased + 127
    frac = sig24 & 0x7FFFFF
    return ((sign << 31) | (exp << 23) | frac) & 0xFFFFFFFF


def fp32_mul_q16_bits(a_bits: int, b_bits: int) -> int:
    a_q = _fp32_to_q16_16_signed(a_bits)
    b_q = _fp32_to_q16_16_signed(b_bits)
    prod_q32_32 = a_q * b_q
    if prod_q32_32 >= 0:
        prod_round = prod_q32_32 + 32768
    else:
        prod_round = prod_q32_32 - 32768
    prod_q16_16 = prod_round >> 16
    if prod_q16_16 > 0x7FFFFFFF:
        prod_q16_16 = 0x7FFFFFFF
    if prod_q16_16 < -0x80000000:
        prod_q16_16 = -0x80000000
    return _q16_16_signed_to_fp32_bits(prod_q16_16)


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


def attention_bf16_fp32_reference(
    q_mat_bf16: list[list[int]],
    k_mat_bf16: list[list[int]],
    v_mat_bf16: list[list[int]],
    scale_bits: int,
    neg_large_bits: int,
    causal: bool = False,
) -> dict[str, list[list[int]]]:
    seq_len = len(q_mat_bf16)
    d = len(q_mat_bf16[0]) if seq_len > 0 else 0
    out_fp32_bits = [[0 for _ in range(d)] for _ in range(seq_len)]
    out_bf16 = [[0 for _ in range(d)] for _ in range(seq_len)]
    cycle_model = 3 * (seq_len * d // 8) + seq_len * (seq_len * (d + 2) + 1 + (d // 8))

    zero_bits = 0
    zero_bf16 = 0
    for i in range(seq_len):
        m_bits = zero_bits
        l_bits = zero_bits
        acc_bits = [zero_bits for _ in range(d)]
        inv_l_bits = zero_bits
        for j in range(seq_len):
            score_bits = zero_bits
            for kk in range(d):
                prod_bits = fp32_mul_q16_bits(
                    bf16_to_fp32_bits(q_mat_bf16[i][kk]),
                    bf16_to_fp32_bits(k_mat_bf16[j][kk]),
                )
                score_bits = fp32_add_bits(score_bits, prod_bits)
            score_bits = fp32_mul_q16_bits(score_bits, scale_bits)
            if causal and j > i:
                score_bits = neg_large_bits
            score_bf16 = fp32_to_bf16_bits(score_bits)

            step_ref = online_softmax_fp32_step(
                m_old_bits=m_bits,
                l_old_bits=l_bits,
                acc_old_bits=zero_bits,
                score_bf16=score_bf16,
                value_bf16=zero_bf16,
                row_start=(j == 0),
            )
            m_bits = step_ref["m_new_bits"]
            l_bits = step_ref["l_new_bits"]
            exp_old_bits = step_ref["exp_old_bits"]
            exp_new_bits = step_ref["exp_new_bits"]

            l_val = bits_to_f32(l_bits)
            inv_l_bits = zero_bits if l_val == 0.0 else f32_to_bits(f32(1.0 / l_val))

            for kk in range(d):
                acc_scaled = zero_bits if j == 0 else fp32_mul_q16_bits(acc_bits[kk], exp_old_bits)
                v_term = fp32_mul_q16_bits(bf16_to_fp32_bits(v_mat_bf16[j][kk]), exp_new_bits)
                acc_bits[kk] = fp32_add_bits(acc_scaled, v_term)

        for kk in range(d):
            out_bits = fp32_mul_q16_bits(acc_bits[kk], inv_l_bits)
            out_fp32_bits[i][kk] = out_bits
            out_bf16[i][kk] = fp32_to_bf16_bits(out_bits)

    return {
        "o_fp32_bits": out_fp32_bits,
        "o_bf16": out_bf16,
        "cycle_model": cycle_model,
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
