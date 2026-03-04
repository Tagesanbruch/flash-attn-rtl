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

uint32_t recip_q16_16(uint32_t x_q16_16) {
    if (x_q16_16 == 0) return 0xFFFFFFFFu;
    uint64_t num = (1ull << 32);
    uint64_t q = num / x_q16_16;
    if (q > 0xFFFFFFFFull) return 0xFFFFFFFFu;
    return static_cast<uint32_t>(q);
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
