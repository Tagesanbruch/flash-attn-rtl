#include "attention_core.hpp"

#include <algorithm>
#include <cmath>

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

} // namespace attn
