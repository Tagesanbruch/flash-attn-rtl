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
    elif x_q8_8 < -2048:
        x_q8_8 = -2048

    u_q8_8 = -x_q8_8
    u_int = (u_q8_8 >> 8) & 0xFF
    if u_int >= 8:
        seg_idx = 7
        frac = 255
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
    x = max(min(x_q8_8 / 256.0, 0.0), -8.0)
    y = math.exp(x)
    return max(0, min(65535, int(round(y * 32768))))
