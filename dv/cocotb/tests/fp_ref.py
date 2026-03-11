import math


def to_s16(value: int) -> int:
    value &= 0xFFFF
    if value & 0x8000:
        return value - 0x10000
    return value


def to_u16(value: int) -> int:
    return value & 0xFFFF


def to_s32(value: int) -> int:
    value &= 0xFFFFFFFF
    if value & 0x80000000:
        return value - 0x100000000
    return value


def to_u32(value: int) -> int:
    return value & 0xFFFFFFFF


def q8_8_mul_sat(a: int, b: int) -> int:
    prod = a * b
    if prod >= 0:
        rounded = prod + 128
    else:
        rounded = prod - 128
    shifted = rounded >> 8
    if shifted > 32767:
        return 32767
    if shifted < -32768:
        return -32768
    return shifted


def exp_pwl_q1_15(x_q8_8: int) -> int:
    if x_q8_8 > 0:
        x_q8_8 = 0
    elif x_q8_8 < -4096:
        x_q8_8 = -4096

    u_q8_8 = -x_q8_8
    u_int = (u_q8_8 >> 8) & 0xFF
    if u_int >= 8:
        return 0
    else:
        seg_idx = (u_q8_8 >> 8) & 0x7
        frac = u_q8_8 & 0xFF

    table = [
        (32767, 12055),
        (12055, 4431),
        (4431, 1631),
        (1631, 600),
        (600, 221),
        (221, 81),
        (81, 30),
        (30, 11),
    ]
    y0, y1 = table[seg_idx]
    delta = y0 - y1
    interp_term = delta * frac
    y = y0 - (interp_term >> 8)
    return y & 0xFFFF


def recip_q16_16(x_q16_16: int) -> int:
    x_q16_16 &= 0xFFFFFFFF
    if x_q16_16 == 0:
        return 0xFFFFFFFF
    num = 1 << 32
    q = num // x_q16_16
    if q > 0xFFFFFFFF:
        return 0xFFFFFFFF
    return q & 0xFFFFFFFF


def online_softmax_step(m_reg: int, l_reg_u32: int, acc_reg: int, score: int, value: int):
    m_new = score if score > m_reg else m_reg
    diff_old = m_reg - m_new
    diff_new = score - m_new

    exp_old = exp_pwl_q1_15(diff_old)
    exp_new = exp_pwl_q1_15(diff_new)

    l_scaled = (l_reg_u32 * exp_old) >> 15
    l_term = (exp_new << 1) & 0xFFFFFFFF
    l_new = (l_scaled + l_term) & 0xFFFFFFFF

    acc_scaled = (acc_reg * exp_old) >> 15
    v_mul = exp_new * value
    v_term = v_mul >> 7
    acc_new = to_s32(acc_scaled + v_term)

    return to_s16(m_new), to_u32(l_new), to_s32(acc_new)


def q8_8_to_float(x: int) -> float:
    return float(to_s16(x)) / 256.0


def q1_15_to_float(x: int) -> float:
    return float(to_u16(x)) / 32768.0


def q16_16_to_float_signed(x: int) -> float:
    return float(to_s32(x)) / 65536.0


def exp_real_q1_15(x_q8_8: int) -> int:
    x = max(min(x_q8_8 / 256.0, 0.0), -16.0)
    y = math.exp(x)
    return max(0, min(65535, int(round(y * 32768))))


def exp2_ctx_q1_15(x_q8_8: int) -> int:
    x_q8_8 = max(min(x_q8_8, 0), -4096)
    z_q8_8 = ((-x_q8_8) * 369 + 128) >> 8
    int_part = (z_q8_8 >> 8) & 0xFF
    frac_part = z_q8_8 & 0xFF
    table = [
        32768, 32066, 31379, 30706, 30048, 29405, 28774, 28158,
        27554, 26964, 26386, 25821, 25268, 24726, 24196, 23678,
        23170, 22674, 22188, 21713, 21247, 20792, 20347, 19911,
        19484, 19066, 18658, 18258, 17867, 17484, 17109, 16743,
    ]
    if int_part >= 16:
        return 0
    return (table[frac_part >> 3] >> int_part) & 0xFFFF


def recip_nr_rtl_q16_16(x_q16_16: int) -> int:
    x_q16_16 &= 0xFFFFFFFF
    lut = [
        0xFC0FC0FC, 0xF4898D60, 0xED7303B6, 0xE6C2B448,
        0xE070381C, 0xDA740DA7, 0xD4C77B03, 0xCF6474A9,
        0xCA4587E7, 0xC565C87B, 0xC0C0C0C1, 0xBC52640C,
        0xB81702E0, 0xB40B40B4, 0xB02C0B03, 0xAC769184,
        0xA8E83F57, 0xA57EB503, 0xA237C32B, 0x9F1165E7,
        0x9C09C09C, 0x991F1A51, 0x964FDA6C, 0x939A85C4,
        0x90FDBC09, 0x8E78356D, 0x8C08C08C, 0x89AE408A,
        0x8767AB5F, 0x85340853, 0x83126E98, 0x81020408,
    ]

    def clz32(val: int) -> int:
        if val == 0:
            return 32
        n = 0
        x = val & 0xFFFFFFFF
        if (x >> 16) == 0:
            n += 16
            x <<= 16
        if (x >> 24) == 0:
            n += 8
            x <<= 8
        if (x >> 28) == 0:
            n += 4
            x <<= 4
        if (x >> 30) == 0:
            n += 2
            x <<= 2
        if (x >> 31) == 0:
            n += 1
        return n

    def mul_q1_31(a: int, b: int) -> int:
        return ((a * b) >> 32) & 0xFFFFFFFF

    def mul_q1_31_corr(a: int, b: int, corr_ov: bool) -> int:
        if corr_ov:
            return a & 0xFFFFFFFF
        return ((a * b) >> 31) & 0xFFFFFFFF

    lz = clz32(x_q16_16)
    d_norm = (x_q16_16 << lz) & 0xFFFFFFFF
    is_zero = x_q16_16 == 0
    is_one = x_q16_16 == 1
    r0 = lut[(d_norm >> 26) & 0x1F]
    dr0_q1_31 = mul_q1_31(d_norm, r0)
    corr1_w = (1 << 32) - dr0_q1_31
    r1 = mul_q1_31_corr(r0, corr1_w & 0xFFFFFFFF, bool((corr1_w >> 32) & 0x1))
    dr1_q1_31 = mul_q1_31(d_norm, r1)
    corr2_w = (1 << 32) - dr1_q1_31
    r2 = mul_q1_31_corr(r1, corr2_w & 0xFFFFFFFF, bool((corr2_w >> 32) & 0x1))

    if is_zero or is_one:
        return 0xFFFFFFFF
    if lz >= 31:
        result_wide = r2 << (lz - 31)
        return 0xFFFFFFFF if (result_wide >> 32) else (result_wide & 0xFFFFFFFF)
    return (r2 >> (31 - lz)) & 0xFFFFFFFF
