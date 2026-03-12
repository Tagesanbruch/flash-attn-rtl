#include "attention_core.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace attn {

int16_t sat_s16(int32_t v) {
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return static_cast<int16_t>(v);
}

int32_t to_s32(int64_t v) {
    uint32_t u = static_cast<uint32_t>(v & 0xFFFFFFFFu);
    return static_cast<int32_t>(u);
}

uint32_t to_u32(uint64_t v) {
    return static_cast<uint32_t>(v & 0xFFFFFFFFu);
}

int16_t q8_8_mul_sat(int16_t a, int16_t b) {
    int32_t prod = static_cast<int32_t>(a) * static_cast<int32_t>(b);
    int32_t rounded = (prod >= 0) ? (prod + 128) : (prod - 128);
    int32_t shifted = rounded >> 8;
    return sat_s16(shifted);
}

uint16_t exp_pwl_q1_15(int16_t x_q8_8) {
    int32_t x = x_q8_8;
    if (x > 0) x = 0;
    if (x < -2048) x = -2048;

    int32_t u_q8_8 = -x;
    int seg_idx;
    int frac;
    int u_int = (u_q8_8 >> 8) & 0xFF;
    if (u_int >= 8) {
        seg_idx = 7;
        frac = 255;
    } else {
        seg_idx = (u_q8_8 >> 8) & 0x7;
        frac = u_q8_8 & 0xFF;
    }

    static const int table[8][2] = {
        {32767, 12055}, {12055, 4431}, {4431, 1631}, {1631, 600},
        {600, 221}, {221, 81}, {81, 30}, {30, 11},
    };

    int y0 = table[seg_idx][0];
    int y1 = table[seg_idx][1];
    int delta = y0 - y1;
    int interp_term = delta * frac;
    int y = y0 - (interp_term >> 8);
    return static_cast<uint16_t>(y & 0xFFFF);
}

uint16_t exp_real_q1_15(int16_t x_q8_8) {
    double x = static_cast<double>(x_q8_8) / 256.0;
    if (x > 0.0) x = 0.0;
    if (x < -16.0) x = -16.0;
    int v = static_cast<int>(std::llround(std::exp(x) * 32768.0));
    v = std::max(0, std::min(65535, v));
    return static_cast<uint16_t>(v);
}

namespace {

constexpr int kCtxExp2Table[32] = {
    32768, 32066, 31379, 30706, 30048, 29405, 28774, 28158,
    27554, 26964, 26386, 25821, 25268, 24726, 24196, 23678,
    23170, 22674, 22188, 21713, 21247, 20792, 20347, 19911,
    19484, 19066, 18658, 18258, 17867, 17484, 17109, 16743,
};

} // namespace

uint16_t exp2_ctx_step_q1_15(int16_t x_q8_8) {
    int32_t x = x_q8_8;
    if (x > 0) x = 0;
    if (x < -4096) x = -4096;

    uint32_t mag_q8_8 = static_cast<uint32_t>(-x);
    uint32_t z_mul_q16_16 = mag_q8_8 * 369u;
    uint32_t z_q8_8 = (z_mul_q16_16 + 128u) >> 8;
    uint32_t int_part = (z_q8_8 >> 8) & 0xFFu;
    uint32_t frac_part = z_q8_8 & 0xFFu;
    if (int_part >= 16u) return 0;
    return static_cast<uint16_t>(kCtxExp2Table[frac_part >> 3] >> int_part);
}

uint16_t exp2_ctx_interp_q1_15(int16_t x_q8_8) {
    int32_t x = x_q8_8;
    if (x > 0) x = 0;
    if (x < -4096) x = -4096;

    uint32_t mag_q8_8 = static_cast<uint32_t>(-x);
    uint32_t z_mul_q16_16 = mag_q8_8 * 369u;
    uint32_t z_q8_8 = (z_mul_q16_16 + 128u) >> 8;
    uint32_t int_part = (z_q8_8 >> 8) & 0xFFu;
    uint32_t frac_part = z_q8_8 & 0xFFu;
    if (int_part >= 16u) return 0;

    uint32_t idx = frac_part >> 3;
    uint32_t frac_lo = frac_part & 0x7u;
    int y0 = kCtxExp2Table[idx];
    int y1 = (idx >= 31u) ? 0 : kCtxExp2Table[idx + 1];
    int delta = y0 - y1;
    int interp = y0 - ((delta * static_cast<int>(frac_lo) + 4) >> 3);
    if (interp < 0) interp = 0;
    return static_cast<uint16_t>(interp >> int_part);
}

uint32_t recip_q16_16(uint32_t x_q16_16) {
    if (x_q16_16 == 0) return 0xFFFFFFFFu;
    uint64_t num = (1ull << 32);
    uint64_t q = num / x_q16_16;
    if (q > 0xFFFFFFFFull) return 0xFFFFFFFFu;
    return static_cast<uint32_t>(q);
}

namespace {

uint32_t mul_q1_31(uint32_t a, uint32_t b) {
    uint64_t pp_hh = static_cast<uint64_t>(a >> 16) * static_cast<uint64_t>(b >> 16);
    uint64_t pp_hl = static_cast<uint64_t>(a >> 16) * static_cast<uint64_t>(b & 0xFFFFu);
    uint64_t pp_lh = static_cast<uint64_t>(a & 0xFFFFu) * static_cast<uint64_t>(b >> 16);
    uint64_t pp_ll = static_cast<uint64_t>(a & 0xFFFFu) * static_cast<uint64_t>(b & 0xFFFFu);
    uint64_t acc = (pp_hh << 32) + (pp_hl << 16) + (pp_lh << 16) + pp_ll;
    return static_cast<uint32_t>(acc >> 32);
}

uint32_t mul_q1_31_corr(uint32_t a, uint32_t b, bool corr_ov) {
    uint64_t pp_hh = static_cast<uint64_t>(a >> 16) * static_cast<uint64_t>(b >> 16);
    uint64_t pp_hl = static_cast<uint64_t>(a >> 16) * static_cast<uint64_t>(b & 0xFFFFu);
    uint64_t pp_lh = static_cast<uint64_t>(a & 0xFFFFu) * static_cast<uint64_t>(b >> 16);
    uint64_t pp_ll = static_cast<uint64_t>(a & 0xFFFFu) * static_cast<uint64_t>(b & 0xFFFFu);
    uint64_t acc = (pp_hh << 32) + (pp_hl << 16) + (pp_lh << 16) + pp_ll;
    return corr_ov ? a : static_cast<uint32_t>(acc >> 31);
}

int clz32_cpp(uint32_t val) {
    if (val == 0) return 32;
    int n = 0;
    uint32_t x = val;
    if ((x >> 16) == 0) { n += 16; x <<= 16; }
    if ((x >> 24) == 0) { n += 8; x <<= 8; }
    if ((x >> 28) == 0) { n += 4; x <<= 4; }
    if ((x >> 30) == 0) { n += 2; x <<= 2; }
    if ((x >> 31) == 0) { n += 1; }
    return n;
}

} // namespace

uint32_t recip_nr_rtl_q16_16(uint32_t x_q16_16) {
    static const uint32_t lut[32] = {
        0xFC0FC0FCu, 0xF4898D60u, 0xED7303B6u, 0xE6C2B448u,
        0xE070381Cu, 0xDA740DA7u, 0xD4C77B03u, 0xCF6474A9u,
        0xCA4587E7u, 0xC565C87Bu, 0xC0C0C0C1u, 0xBC52640Cu,
        0xB81702E0u, 0xB40B40B4u, 0xB02C0B03u, 0xAC769184u,
        0xA8E83F57u, 0xA57EB503u, 0xA237C32Bu, 0x9F1165E7u,
        0x9C09C09Cu, 0x991F1A51u, 0x964FDA6Cu, 0x939A85C4u,
        0x90FDBC09u, 0x8E78356Du, 0x8C08C08Cu, 0x89AE408Au,
        0x8767AB5Fu, 0x85340853u, 0x83126E98u, 0x81020408u,
    };

    int lz = clz32_cpp(x_q16_16);
    uint32_t d_norm = x_q16_16 << lz;
    bool is_zero = (x_q16_16 == 0);
    bool is_one = (x_q16_16 == 1);

    uint32_t r0 = lut[(d_norm >> 26) & 0x1Fu];
    uint32_t dr0_q1_31 = mul_q1_31(d_norm, r0);
    uint64_t corr1_w = (1ull << 32) - static_cast<uint64_t>(dr0_q1_31);
    uint32_t corr1 = static_cast<uint32_t>(corr1_w & 0xFFFFFFFFu);
    bool corr1_ov = ((corr1_w >> 32) & 0x1u) != 0;
    uint32_t r1 = mul_q1_31_corr(r0, corr1, corr1_ov);

    uint32_t dr1_q1_31 = mul_q1_31(d_norm, r1);
    uint64_t corr2_w = (1ull << 32) - static_cast<uint64_t>(dr1_q1_31);
    uint32_t corr2 = static_cast<uint32_t>(corr2_w & 0xFFFFFFFFu);
    bool corr2_ov = ((corr2_w >> 32) & 0x1u) != 0;
    uint32_t r2 = mul_q1_31_corr(r1, corr2, corr2_ov);

    if (is_zero || is_one) return 0xFFFFFFFFu;

    if (lz >= 31) {
        uint64_t result_wide = static_cast<uint64_t>(r2) << (lz - 31);
        return (result_wide >> 32) ? 0xFFFFFFFFu : static_cast<uint32_t>(result_wide);
    }
    return r2 >> (31 - lz);
}

float q8_8_to_float(int16_t x) {
    return static_cast<float>(x) / 256.0f;
}

int16_t float_to_q8_8(float x) {
    int v = static_cast<int>(std::lround(static_cast<double>(x) * 256.0));
    return sat_s16(v);
}

MatrixF dequant_q8_8(const MatrixI16& x) {
    MatrixF out(x.size(), std::vector<float>(x[0].size(), 0.0f));
    for (size_t i = 0; i < x.size(); ++i) {
        for (size_t j = 0; j < x[0].size(); ++j) {
            out[i][j] = q8_8_to_float(x[i][j]);
        }
    }
    return out;
}

MatrixI16 quant_q8_8(const MatrixF& x) {
    MatrixI16 out(x.size(), std::vector<int16_t>(x[0].size(), 0));
    for (size_t i = 0; i < x.size(); ++i) {
        for (size_t j = 0; j < x[0].size(); ++j) {
            out[i][j] = float_to_q8_8(x[i][j]);
        }
    }
    return out;
}

uint32_t f32_to_bits(float v) {
    uint32_t bits = 0;
    std::memcpy(&bits, &v, sizeof(bits));
    return bits;
}

float bits_to_f32(uint32_t bits) {
    float v = 0.0f;
    std::memcpy(&v, &bits, sizeof(v));
    return v;
}

uint16_t fp32_to_bf16_bits(uint32_t x_bits) {
    uint32_t sign = (x_bits >> 31) & 0x1u;
    uint32_t exp = (x_bits >> 23) & 0xFFu;
    uint32_t frac = x_bits & 0x7FFFFFu;
    if (exp == 0xFFu && frac != 0u) {
        uint32_t payload = (frac >> 16) & 0x7Fu;
        if (payload == 0u) payload = 0x40u;
        return static_cast<uint16_t>((sign << 15) | (0xFFu << 7) | payload);
    }
    uint32_t rounded = x_bits + 0x7FFFu + ((x_bits >> 16) & 0x1u);
    return static_cast<uint16_t>((rounded >> 16) & 0xFFFFu);
}

uint32_t bf16_to_fp32_bits(uint16_t bf16) {
    return static_cast<uint32_t>(bf16) << 16;
}

uint32_t fp32_neg_bits(uint32_t x_bits) {
    return x_bits ^ 0x80000000u;
}

uint32_t fp32_add_ref_bits(uint32_t a_bits, uint32_t b_bits) {
    uint32_t a_exp = (a_bits >> 23) & 0xFFu;
    uint32_t a_frac = a_bits & 0x7FFFFFu;
    uint32_t b_exp = (b_bits >> 23) & 0xFFu;
    uint32_t b_frac = b_bits & 0x7FFFFFu;
    bool a_is_nan = (a_exp == 0xFFu) && (a_frac != 0u);
    bool b_is_nan = (b_exp == 0xFFu) && (b_frac != 0u);
    bool a_is_inf = (a_exp == 0xFFu) && (a_frac == 0u);
    bool b_is_inf = (b_exp == 0xFFu) && (b_frac == 0u);
    bool a_sign = (a_bits >> 31) & 0x1u;
    bool b_sign = (b_bits >> 31) & 0x1u;
    if (a_is_nan || b_is_nan || (a_is_inf && b_is_inf && (a_sign != b_sign))) {
        return 0x7FC00000u;
    }
    float sum = bits_to_f32(a_bits) + bits_to_f32(b_bits);
    return f32_to_bits(sum);
}

namespace {

uint32_t round_shift_right_rne_32(uint32_t value, int shamt) {
    if (shamt <= 0) return value;
    if (shamt >= 32) return (value != 0u) ? 1u : 0u;
    uint32_t base = value >> shamt;
    uint32_t guard = (value >> (shamt - 1)) & 0x1u;
    uint32_t sticky_mask = (shamt > 1) ? ((1u << (shamt - 1)) - 1u) : 0u;
    uint32_t sticky = (value & sticky_mask) ? 1u : 0u;
    if (guard && (sticky || (base & 0x1u))) return base + 1u;
    return base;
}

uint32_t shift_right_sticky_27(uint32_t value, int shamt) {
    if (shamt <= 0) return value & 0x7FFFFFFu;
    if (shamt >= 27) return (value != 0u) ? 1u : 0u;
    uint32_t shifted = value >> shamt;
    uint32_t lost_mask = (1u << shamt) - 1u;
    uint32_t sticky = (value & lost_mask) ? 1u : 0u;
    shifted |= sticky;
    return shifted & 0x7FFFFFFu;
}

int find_msb_idx_u32(uint32_t v) {
    if (v == 0u) return -1;
    int idx = 31;
    while (((v >> idx) & 0x1u) == 0u) --idx;
    return idx;
}

uint32_t q16_16_to_fp32_signed(int32_t q_val) {
    bool sign = (q_val < 0);
    uint32_t mag_q = sign ? static_cast<uint32_t>(-q_val) : static_cast<uint32_t>(q_val);
    if (mag_q == 0u) return sign ? 0x80000000u : 0u;
    int msb_idx = find_msb_idx_u32(mag_q);
    int exp_unbiased = msb_idx - 16;
    int shift_i = msb_idx - 23;
    uint32_t sig24;
    if (shift_i > 0) {
        sig24 = round_shift_right_rne_32(mag_q, shift_i) & 0xFFFFFFu;
    } else {
        sig24 = (mag_q << (23 - msb_idx)) & 0xFFFFFFu;
    }
    if (sig24 & (1u << 24)) {
        sig24 >>= 1;
        exp_unbiased += 1;
    }
    if (exp_unbiased > 127) return (sign ? 0xFF800000u : 0x7F800000u);
    uint32_t exp = static_cast<uint32_t>(exp_unbiased + 127) & 0xFFu;
    uint32_t frac = sig24 & 0x7FFFFFu;
    return (static_cast<uint32_t>(sign) << 31) | (exp << 23) | frac;
}

int32_t fp32_to_q16_16_signed(uint32_t x_bits) {
    bool sign = (x_bits >> 31) & 0x1u;
    uint32_t exp = (x_bits >> 23) & 0xFFu;
    uint32_t frac = x_bits & 0x7FFFFFu;
    if (exp == 0u && frac == 0u) return 0;
    uint32_t sig24 = (exp == 0u) ? frac : (0x800000u | frac);
    int exp_unbiased = (exp == 0u) ? -126 : static_cast<int>(exp) - 127;
    int shift_i = exp_unbiased - 7;
    uint32_t mag_q;
    if (shift_i >= 0) {
        uint64_t tmp64 = static_cast<uint64_t>(sig24) << shift_i;
        if (tmp64 > 0x7FFFFFFFull) mag_q = 0x7FFFFFFFu;
        else mag_q = static_cast<uint32_t>(tmp64);
    } else {
        mag_q = round_shift_right_rne_32(sig24, -shift_i);
        if (mag_q > 0x7FFFFFFFu) mag_q = 0x7FFFFFFFu;
    }
    return sign ? -static_cast<int32_t>(mag_q) : static_cast<int32_t>(mag_q);
}

uint32_t q16_16_to_fp32_unsigned(bool sign, uint32_t q_val) {
    if (q_val == 0u) return sign ? 0x80000000u : 0u;
    int msb_idx = find_msb_idx_u32(q_val);
    int exp_unbiased = msb_idx - 16;
    int shift_i = msb_idx - 23;
    uint32_t sig24;
    if (shift_i > 0) {
        sig24 = round_shift_right_rne_32(q_val, shift_i) & 0xFFFFFFu;
    } else {
        sig24 = (q_val << (23 - msb_idx)) & 0xFFFFFFu;
    }
    if (sig24 & (1u << 24)) {
        sig24 >>= 1;
        exp_unbiased += 1;
    }
    if (exp_unbiased > 127) return (sign ? 0xFF800000u : 0x7F800000u);
    uint32_t exp = static_cast<uint32_t>(exp_unbiased + 127) & 0xFFu;
    uint32_t frac = sig24 & 0x7FFFFFu;
    return (static_cast<uint32_t>(sign) << 31) | (exp << 23) | frac;
}

uint32_t fp32_abs_to_q16_16(uint32_t abs_bits) {
    uint32_t exp = (abs_bits >> 23) & 0xFFu;
    uint32_t frac = abs_bits & 0x7FFFFFu;
    if (exp == 0u && frac == 0u) return 0u;
    uint32_t sig24 = (exp == 0u) ? frac : (0x800000u | frac);
    int exp_unbiased = (exp == 0u) ? -126 : static_cast<int>(exp) - 127;
    int shift_i = exp_unbiased - 7;
    if (shift_i >= 0) {
        uint64_t tmp64 = static_cast<uint64_t>(sig24) << shift_i;
        if (tmp64 > 0xFFFFFFFFull) return 0xFFFFFFFFu;
        return static_cast<uint32_t>(tmp64);
    }
    return round_shift_right_rne_32(sig24, -shift_i);
}

uint32_t fp32_to_q8_8(uint32_t x_bits) {
    bool sign = (x_bits >> 31) & 0x1u;
    uint32_t exp = (x_bits >> 23) & 0xFFu;
    uint32_t frac = x_bits & 0x7FFFFFu;
    if (exp == 0u && frac == 0u) return 0u;
    uint32_t sig24 = (exp == 0u) ? frac : (0x800000u | frac);
    int exp_unbiased = (exp == 0u) ? -126 : static_cast<int>(exp) - 127;
    int shift_i = exp_unbiased - 15;
    uint32_t mag_q8_8;
    if (shift_i >= 0) {
        uint64_t tmp64 = static_cast<uint64_t>(sig24) << shift_i;
        if (tmp64 > 32768ull) mag_q8_8 = 32768u;
        else mag_q8_8 = static_cast<uint32_t>(tmp64);
    } else {
        mag_q8_8 = round_shift_right_rne_32(sig24, -shift_i);
    }
    if (sign) {
        if (mag_q8_8 >= 32768u) return static_cast<uint32_t>(static_cast<int16_t>(-32768));
        return static_cast<uint32_t>(static_cast<int16_t>(-static_cast<int16_t>(mag_q8_8 & 0xFFFFu)));
    }
    if (mag_q8_8 >= 32767u) return static_cast<uint32_t>(static_cast<int16_t>(32767));
    return static_cast<uint32_t>(static_cast<int16_t>(mag_q8_8 & 0xFFFFu));
}

uint32_t exp2_pwl_point(uint32_t idx) {
    static const uint32_t table[16] = {
        65536u, 68438u, 71468u, 74632u,
        77936u, 81386u, 84990u, 88752u,
        92682u, 96785u, 101070u, 105545u,
        110218u, 115098u, 120194u, 125515u
    };
    if (idx < 16u) return table[idx];
    return 131072u;
}

} // namespace

uint32_t fp32_add_rtl_bits(uint32_t i_a, uint32_t i_b) {
    bool a_sign = (i_a >> 31) & 0x1u;
    uint32_t a_exp = (i_a >> 23) & 0xFFu;
    uint32_t a_frac = i_a & 0x7FFFFFu;
    bool b_sign = (i_b >> 31) & 0x1u;
    uint32_t b_exp = (i_b >> 23) & 0xFFu;
    uint32_t b_frac = i_b & 0x7FFFFFu;

    bool a_is_nan = (a_exp == 0xFFu) && (a_frac != 0u);
    bool b_is_nan = (b_exp == 0xFFu) && (b_frac != 0u);
    bool a_is_inf = (a_exp == 0xFFu) && (a_frac == 0u);
    bool b_is_inf = (b_exp == 0xFFu) && (b_frac == 0u);
    bool a_is_zero = (a_exp == 0u) && (a_frac == 0u);
    bool b_is_zero = (b_exp == 0u) && (b_frac == 0u);

    uint32_t a_exp_eff = (a_exp == 0u) ? 1u : a_exp;
    uint32_t b_exp_eff = (b_exp == 0u) ? 1u : b_exp;
    uint32_t a_sig = (a_exp == 0u) ? a_frac : (0x800000u | a_frac);
    uint32_t b_sig = (b_exp == 0u) ? b_frac : (0x800000u | b_frac);

    bool large_sign;
    bool small_sign;
    uint32_t large_exp_eff;
    uint32_t small_exp_eff;
    uint32_t large_sig;
    uint32_t small_sig;

    if ((a_exp_eff > b_exp_eff) || ((a_exp_eff == b_exp_eff) && (a_sig >= b_sig))) {
        large_sign = a_sign;
        large_exp_eff = a_exp_eff;
        large_sig = a_sig;
        small_sign = b_sign;
        small_exp_eff = b_exp_eff;
        small_sig = b_sig;
    } else {
        large_sign = b_sign;
        large_exp_eff = b_exp_eff;
        large_sig = b_sig;
        small_sign = a_sign;
        small_exp_eff = a_exp_eff;
        small_sig = a_sig;
    }

    uint32_t large_sig_ext = (large_sig << 3) & 0x7FFFFFFu;
    uint32_t small_sig_ext = (small_sig << 3) & 0x7FFFFFFu;
    int shift_amt = static_cast<int>(large_exp_eff) - static_cast<int>(small_exp_eff);
    uint32_t small_sig_shifted = shift_right_sticky_27(small_sig_ext, shift_amt);

    if (a_is_nan || b_is_nan) return 0x7FC00000u;
    if (a_is_inf && b_is_inf && (a_sign != b_sign)) return 0x7FC00000u;
    if (a_is_inf) return (a_sign ? 0xFF800000u : 0x7F800000u);
    if (b_is_inf) return (b_sign ? 0xFF800000u : 0x7F800000u);
    if (a_is_zero && b_is_zero) return (a_sign && b_sign) ? 0x80000000u : 0u;

    bool sign_work = large_sign;
    uint32_t exp_work = large_exp_eff;
    uint32_t sig_work = 0u;

    if (large_sign == small_sign) {
        uint32_t add_sum_ext = (large_sig_ext + small_sig_shifted) & 0xFFFFFFFu;
        if (add_sum_ext & 0x8000000u) {
            sig_work = (add_sum_ext >> 1) & 0x7FFFFFFu;
            sig_work |= (add_sum_ext & 0x1u);
            exp_work = large_exp_eff + 1u;
        } else {
            sig_work = add_sum_ext & 0x7FFFFFFu;
        }
    } else {
        if (large_sig_ext >= small_sig_shifted) {
            sig_work = (large_sig_ext - small_sig_shifted) & 0x7FFFFFFu;
        } else {
            sig_work = 0u;
        }
        if (sig_work == 0u) {
            sign_work = false;
            exp_work = 0u;
        } else {
            while (((sig_work >> 26) & 0x1u) == 0u && exp_work > 1u) {
                sig_work = (sig_work << 1) & 0x7FFFFFFu;
                exp_work -= 1u;
            }
        }
    }

    if (sig_work == 0u) return sign_work ? 0x80000000u : 0u;

    if ((sig_work >> 26) & 0x1u) {
        uint32_t round_tmp = (sig_work >> 3) & 0x1FFFFFFu;
        if ((sig_work & 0x4u) && ((sig_work & 0x3u) || (sig_work & 0x8u))) {
            round_tmp += 1u;
        }
        if (round_tmp & 0x1000000u) {
            if (exp_work >= 0xFEu) {
                return sign_work ? 0xFF800000u : 0x7F800000u;
            }
            return (static_cast<uint32_t>(sign_work) << 31) | ((exp_work + 1u) << 23);
        }
        if (exp_work >= 0xFFu) return sign_work ? 0xFF800000u : 0x7F800000u;
        uint32_t frac_work = round_tmp & 0x7FFFFFu;
        if (exp_work == 1u && ((round_tmp >> 23) & 0x1u) == 0u) {
            uint32_t sub_round_tmp = (sig_work >> 3) & 0xFFFFFFu;
            if ((sig_work & 0x4u) && ((sig_work & 0x3u) || (sig_work & 0x8u))) {
                sub_round_tmp += 1u;
            }
            if (sub_round_tmp & 0x800000u) {
                return (static_cast<uint32_t>(sign_work) << 31) | (1u << 23);
            }
            return (static_cast<uint32_t>(sign_work) << 31) | (sub_round_tmp & 0x7FFFFFu);
        }
        return (static_cast<uint32_t>(sign_work) << 31) | (exp_work << 23) | frac_work;
    }

    uint32_t sub_round_tmp = (sig_work >> 3) & 0xFFFFFFu;
    if ((sig_work & 0x4u) && ((sig_work & 0x3u) || (sig_work & 0x8u))) {
        sub_round_tmp += 1u;
    }
    if (sub_round_tmp & 0x800000u) {
        return (static_cast<uint32_t>(sign_work) << 31) | (1u << 23);
    }
    return (static_cast<uint32_t>(sign_work) << 31) | (sub_round_tmp & 0x7FFFFFu);
}

uint32_t fp32_mul_q16_bits(uint32_t a_bits, uint32_t b_bits) {
    int32_t a_q = fp32_to_q16_16_signed(a_bits);
    int32_t b_q = fp32_to_q16_16_signed(b_bits);
    int64_t prod_q32_32 = static_cast<int64_t>(a_q) * static_cast<int64_t>(b_q);
    int64_t prod_round = (prod_q32_32 >= 0) ? (prod_q32_32 + 32768ll) : (prod_q32_32 - 32768ll);
    int32_t prod_q16_16 = static_cast<int32_t>(prod_round >> 16);
    if (prod_q16_16 > 0x7FFFFFFF) prod_q16_16 = 0x7FFFFFFF;
    if (prod_q16_16 < static_cast<int32_t>(0x80000000u)) prod_q16_16 = static_cast<int32_t>(0x80000000u);
    return q16_16_to_fp32_signed(prod_q16_16);
}

uint32_t fp32_exp2_pwl_bits(uint32_t i_x_fp32) {
    bool x_sign = (i_x_fp32 >> 31) & 0x1u;
    uint32_t x_exp = (i_x_fp32 >> 23) & 0xFFu;
    uint32_t x_frac = i_x_fp32 & 0x7FFFFFu;
    bool x_is_nan = (x_exp == 0xFFu) && (x_frac != 0u);
    bool x_is_inf = (x_exp == 0xFFu) && (x_frac == 0u);

    int16_t x_q8_8 = static_cast<int16_t>(fp32_to_q8_8(i_x_fp32));
    int16_t x_clip_q8_8 = x_q8_8;

    if (x_is_nan) return 0x7FC00000u;
    if (x_is_inf && !x_sign) return 0x7F800000u;
    if (x_is_inf && x_sign) return 0u;

    if (x_q8_8 > 4095) return 0x7F800000u;
    if (x_q8_8 < -4096) x_clip_q8_8 = -4096;

    int16_t int_part = 0;
    uint16_t frac_part = 0u;
    if (x_clip_q8_8 >= 0) {
        int_part = static_cast<int16_t>(x_clip_q8_8 >> 8);
        frac_part = static_cast<uint16_t>(x_clip_q8_8 & 0xFF);
    } else {
        uint16_t mag_q8_8 = static_cast<uint16_t>(-x_clip_q8_8);
        if ((mag_q8_8 & 0xFFu) == 0u) {
            int_part = -static_cast<int16_t>(mag_q8_8 >> 8);
            frac_part = 0u;
        } else {
            int_part = -static_cast<int16_t>(mag_q8_8 >> 8) - 1;
            frac_part = static_cast<uint16_t>(0u - (mag_q8_8 & 0xFFu));
        }
    }

    uint32_t seg_idx = (frac_part >> 4) & 0xFu;
    uint32_t seg_frac = frac_part & 0xFu;
    uint32_t y0_q16_16 = exp2_pwl_point(seg_idx);
    uint32_t y1_q16_16 = exp2_pwl_point(seg_idx + 1u);
    int32_t delta_q16_16 = static_cast<int32_t>(y1_q16_16) - static_cast<int32_t>(y0_q16_16);
    uint32_t interp_mul = static_cast<uint32_t>(delta_q16_16 * static_cast<int32_t>(seg_frac)) & 0x3FFFFFu;
    uint32_t interp_q16_16 = y0_q16_16 + ((interp_mul + 8u) >> 4);

    uint32_t res_q16_16 = 0u;
    if (int_part >= 0) {
        if (int_part >= 16) {
            res_q16_16 = 0xFFFFFFFFu;
        } else {
            uint64_t res_q64 = static_cast<uint64_t>(interp_q16_16) << static_cast<uint32_t>(int_part);
            if (res_q64 > 0xFFFFFFFFull) res_q16_16 = 0xFFFFFFFFu;
            else res_q16_16 = static_cast<uint32_t>(res_q64);
        }
    } else {
        int rshift_i = -int_part;
        if (rshift_i >= 32) res_q16_16 = 0u;
        else res_q16_16 = interp_q16_16 >> rshift_i;
    }

    return q16_16_to_fp32_unsigned(false, res_q16_16);
}

uint32_t fp32_recip_bits(uint32_t i_x_fp32) {
    bool x_sign = (i_x_fp32 >> 31) & 0x1u;
    uint32_t x_exp = (i_x_fp32 >> 23) & 0xFFu;
    uint32_t x_frac = i_x_fp32 & 0x7FFFFFu;
    bool x_is_nan = (x_exp == 0xFFu) && (x_frac != 0u);
    bool x_is_inf = (x_exp == 0xFFu) && (x_frac == 0u);
    bool x_is_zero = (x_exp == 0u) && (x_frac == 0u);

    if (x_is_nan) return 0x7FC00000u;
    if (x_is_inf) return x_sign ? 0x80000000u : 0u;
    if (x_is_zero) return x_sign ? 0xFF800000u : 0x7F800000u;

    uint32_t x_q16_16 = fp32_abs_to_q16_16(i_x_fp32 & 0x7FFFFFFFu);
    if (x_q16_16 == 0u) return x_sign ? 0xFF800000u : 0x7F800000u;
    uint64_t recip_num = 0x0000000100000000ull;
    uint64_t recip_q64 = recip_num / static_cast<uint64_t>(x_q16_16);
    uint32_t recip_q16_16 = (recip_q64 > 0xFFFFFFFFull) ? 0xFFFFFFFFu : static_cast<uint32_t>(recip_q64);
    return q16_16_to_fp32_unsigned(x_sign, recip_q16_16);
}

uint32_t fp32_max_bits(uint32_t i_a, uint32_t i_b) {
    bool a_sign = (i_a >> 31) & 0x1u;
    uint32_t a_exp = (i_a >> 23) & 0xFFu;
    uint32_t a_frac = i_a & 0x7FFFFFu;
    bool b_sign = (i_b >> 31) & 0x1u;
    uint32_t b_exp = (i_b >> 23) & 0xFFu;
    uint32_t b_frac = i_b & 0x7FFFFFu;

    bool a_is_nan = (a_exp == 0xFFu) && (a_frac != 0u);
    bool b_is_nan = (b_exp == 0xFFu) && (b_frac != 0u);
    bool a_is_zero = (a_exp == 0u) && (a_frac == 0u);
    bool b_is_zero = (b_exp == 0u) && (b_frac == 0u);
    uint32_t a_mag = i_a & 0x7FFFFFFFu;
    uint32_t b_mag = i_b & 0x7FFFFFFFu;

    if (a_is_nan && b_is_nan) return 0x7FC00000u;
    if (a_is_nan) return i_b;
    if (b_is_nan) return i_a;
    if ((a_is_zero && b_is_zero) || (i_a == i_b)) return (a_is_zero && b_is_zero) ? 0u : i_a;
    if (a_sign != b_sign) return a_sign ? i_b : i_a;
    if (!a_sign) return (a_mag > b_mag) ? i_a : i_b;
    return (a_mag < b_mag) ? i_a : i_b;
}

MatrixU16 attention_bf16_fp32_reference(const MatrixU16& q_bf16,
                                        const MatrixU16& k_bf16,
                                        const MatrixU16& v_bf16,
                                        int TQ, int TK,
                                        bool causal,
                                        uint32_t scale_bits,
                                        uint32_t neg_large_bits) {
    const int S = static_cast<int>(q_bf16.size());
    const int D = static_cast<int>(q_bf16[0].size());
    MatrixU16 out(S, std::vector<uint16_t>(D, 0));
    (void)TQ;
    (void)TK;

    uint32_t zero_bits = 0u;

    for (int i = 0; i < S; ++i) {
        uint32_t m_bits = zero_bits;
        uint32_t l_bits = zero_bits;
        std::vector<uint32_t> acc_bits(D, zero_bits);
        uint32_t inv_l_bits = zero_bits;
        for (int j = 0; j < S; ++j) {
            uint32_t score_bits = zero_bits;
            for (int d = 0; d < D; ++d) {
                uint32_t prod_bits = fp32_mul_q16_bits(bf16_to_fp32_bits(q_bf16[i][d]),
                                                       bf16_to_fp32_bits(k_bf16[j][d]));
                score_bits = fp32_add_ref_bits(score_bits, prod_bits);
            }
            score_bits = fp32_mul_q16_bits(score_bits, scale_bits);
            if (causal && j > i) score_bits = neg_large_bits;
            uint16_t score_bf16 = fp32_to_bf16_bits(score_bits);

            uint32_t score_fp32 = bf16_to_fp32_bits(score_bf16);
            uint32_t m_new_bits = m_bits;
            uint32_t exp_old_bits = 0u;
            if (j == 0) {
                m_new_bits = score_fp32;
                exp_old_bits = 0u;
            } else {
                float m_old_f = bits_to_f32(m_bits);
                float score_f = bits_to_f32(score_fp32);
                m_new_bits = (score_f > m_old_f) ? score_fp32 : m_bits;
                uint32_t diff_old = fp32_add_ref_bits(m_bits, fp32_neg_bits(m_new_bits));
                exp_old_bits = f32_to_bits(std::exp2(bits_to_f32(diff_old)));
            }
            uint32_t diff_new = fp32_add_ref_bits(score_fp32, fp32_neg_bits(m_new_bits));
            uint32_t exp_new_bits = f32_to_bits(std::exp2(bits_to_f32(diff_new)));

            uint32_t l_scaled_bits = (j == 0) ? 0u
                : f32_to_bits(bits_to_f32(l_bits) * bits_to_f32(exp_old_bits));
            l_bits = fp32_add_ref_bits(l_scaled_bits, exp_new_bits);

            float l_val = bits_to_f32(l_bits);
            inv_l_bits = (l_val == 0.0f) ? 0u : f32_to_bits(1.0f / l_val);

            for (int d = 0; d < D; ++d) {
                uint32_t acc_scaled = (j == 0) ? 0u : fp32_mul_q16_bits(acc_bits[d], exp_old_bits);
                uint32_t v_term = fp32_mul_q16_bits(bf16_to_fp32_bits(v_bf16[j][d]), exp_new_bits);
                acc_bits[d] = fp32_add_ref_bits(acc_scaled, v_term);
            }
            m_bits = m_new_bits;
        }

        for (int d = 0; d < D; ++d) {
            uint32_t out_bits = fp32_mul_q16_bits(acc_bits[d], inv_l_bits);
            out[i][d] = fp32_to_bf16_bits(out_bits);
        }
    }
    return out;
}

MatrixU16 online_rtl_like_bf16_fp32(const MatrixU16& q_bf16,
                                    const MatrixU16& k_bf16,
                                    const MatrixU16& v_bf16,
                                    int TQ, int TK,
                                    bool causal,
                                    uint32_t scale_bits,
                                    uint32_t neg_large_bits) {
    const int S = static_cast<int>(q_bf16.size());
    const int D = static_cast<int>(q_bf16[0].size());
    MatrixU16 out(S, std::vector<uint16_t>(D, 0));
    for (int qt = 0; qt < S / TQ; ++qt) {
        int q_start = qt * TQ;
        std::vector<uint32_t> row_m(TQ, 0u);
        std::vector<uint32_t> row_l(TQ, 0u);
        std::vector<uint32_t> row_inv(TQ, 0u);
        std::vector<std::vector<uint32_t>> row_acc(TQ, std::vector<uint32_t>(D, 0u));

        for (int kt = 0; kt < S / TK; ++kt) {
            int k_start = kt * TK;
            for (int qi = 0; qi < TQ; ++qi) {
                for (int kj = 0; kj < TK; ++kj) {
                    int gi = q_start + qi;
                    int gj = k_start + kj;
                    uint32_t score_bits = 0u;
                    for (int d = 0; d < D; ++d) {
                        uint32_t prod_bits = fp32_mul_q16_bits(bf16_to_fp32_bits(q_bf16[gi][d]),
                                                               bf16_to_fp32_bits(k_bf16[gj][d]));
                        score_bits = fp32_add_rtl_bits(score_bits, prod_bits);
                    }
                    score_bits = fp32_mul_q16_bits(score_bits, scale_bits);
                    if (causal && (gj > gi)) score_bits = neg_large_bits;

                    uint16_t score_bf16 = fp32_to_bf16_bits(score_bits);
                    uint32_t score_fp32 = bf16_to_fp32_bits(score_bf16);
                    bool row_start = (kt == 0) && (kj == 0);

                    uint32_t m_new_bits = row_start ? score_fp32 : fp32_max_bits(score_fp32, row_m[qi]);
                    uint32_t neg_m_new = fp32_neg_bits(m_new_bits);
                    uint32_t diff_old = fp32_add_rtl_bits(row_m[qi], neg_m_new);
                    uint32_t diff_new = fp32_add_rtl_bits(score_fp32, neg_m_new);
                    uint32_t exp_old = row_start ? 0u : fp32_exp2_pwl_bits(diff_old);
                    uint32_t exp_new = row_start ? 0x3F800000u : fp32_exp2_pwl_bits(diff_new);

                    uint32_t l_scaled = fp32_mul_q16_bits(row_l[qi], exp_old);
                    row_l[qi] = fp32_add_rtl_bits(row_start ? 0u : l_scaled, exp_new);
                    row_inv[qi] = fp32_recip_bits(row_l[qi]);
                    row_m[qi] = m_new_bits;

                    for (int d = 0; d < D; ++d) {
                        uint32_t acc_scaled = fp32_mul_q16_bits(row_acc[qi][d], exp_old);
                        uint32_t v_term = fp32_mul_q16_bits(bf16_to_fp32_bits(v_bf16[gj][d]), exp_new);
                        row_acc[qi][d] = fp32_add_rtl_bits(row_start ? 0u : acc_scaled, v_term);
                    }
                }
            }
        }

        for (int qi = 0; qi < TQ; ++qi) {
            for (int d = 0; d < D; ++d) {
                uint32_t out_bits = fp32_mul_q16_bits(row_acc[qi][d], row_inv[qi]);
                out[q_start + qi][d] = fp32_to_bf16_bits(out_bits);
            }
        }
    }
    return out;
}

} // namespace attn
