#include "attention_core.hpp"

#include <cmath>

namespace attn {

namespace {

int16_t div_round_sat_s16(int64_t num, uint32_t den) {
    if (den == 0) return (num >= 0) ? 32767 : -32768;
    int64_t q;
    if (num >= 0) {
        q = (num + static_cast<int64_t>(den) / 2) / static_cast<int64_t>(den);
    } else {
        q = (num - static_cast<int64_t>(den) / 2) / static_cast<int64_t>(den);
    }
    if (q > 32767) return 32767;
    if (q < -32768) return -32768;
    return static_cast<int16_t>(q);
}

} // namespace

MatrixF direct_sdpa_fp32(const MatrixF& q, const MatrixF& k, const MatrixF& v, bool causal) {
    int S = static_cast<int>(q.size());
    int D = static_cast<int>(q[0].size());
    MatrixF out(S, std::vector<float>(D, 0.0f));
    const float scale = 1.0f / std::sqrt(static_cast<float>(D));

    for (int i = 0; i < S; ++i) {
        std::vector<float> scores(S, 0.0f);
        float max_s = -1e30f;
        for (int j = 0; j < S; ++j) {
            float dot = 0.0f;
            for (int d = 0; d < D; ++d) dot += q[i][d] * k[j][d];
            scores[j] = dot * scale;
            if (causal && j > i) scores[j] = -1e9f;
            if (scores[j] > max_s) max_s = scores[j];
        }
        float denom = 0.0f;
        for (int j = 0; j < S; ++j) {
            scores[j] = std::exp(scores[j] - max_s);
            denom += scores[j];
        }
        for (int j = 0; j < S; ++j) scores[j] /= denom;
        for (int d = 0; d < D; ++d) {
            float acc = 0.0f;
            for (int j = 0; j < S; ++j) acc += scores[j] * v[j][d];
            out[i][d] = acc;
        }
    }
    return out;
}

MatrixI16 online_rtl_like(const MatrixI16& Q, const MatrixI16& K, const MatrixI16& V,
                          int TQ, int TK, bool causal, Mode mode,
                          int16_t neg_large, bool hard_mask) {
    const int S = static_cast<int>(Q.size());
    const int D = static_cast<int>(Q[0].size());
    MatrixI16 O(S, std::vector<int16_t>(D, 0));

    if (mode == Mode::FA_CORE_COMPAT) {
        const float scale_f = 1.0f / std::sqrt(static_cast<float>(D));
        for (int qi = 0; qi < S; ++qi) {
            float m_prev = -1e20f;
            float l_prev = 0.0f;
            std::vector<float> acc(D, 0.0f);

            for (int kj = 0; kj < S; ++kj) {
                if (causal && kj > qi) {
                    if (hard_mask) {
                        continue;
                    }
                }

                int32_t score_acc = 0;
                for (int d = 0; d < D; ++d) {
                    score_acc += static_cast<int32_t>(Q[qi][d]) * static_cast<int32_t>(K[kj][d]);
                }

                float score_f = (static_cast<float>(score_acc) / 65536.0f) * scale_f;
                if (causal && kj > qi && !hard_mask) {
                    score_f = static_cast<float>(neg_large) / 256.0f;
                }

                float m_curr = (score_f > m_prev) ? score_f : m_prev;
                float exp_val = std::exp(score_f - m_curr);
                float exp_factor = std::exp(m_prev - m_curr);

                l_prev = l_prev * exp_factor + exp_val;
                for (int d = 0; d < D; ++d) {
                    acc[d] = acc[d] * exp_factor + exp_val * q8_8_to_float(V[kj][d]);
                }
                m_prev = m_curr;
            }

            float inv_l = 1.0f / (l_prev + 1e-6f);
            for (int d = 0; d < D; ++d) {
                O[qi][d] = float_to_q8_8(acc[d] * inv_l);
            }
        }
        return O;
    }

    if (mode == Mode::FIXED_Q8_IMPROVED) {
        const int16_t scale_q8_8 = static_cast<int16_t>(std::lround((1.0 / std::sqrt(static_cast<double>(D))) * 256.0));
        for (int qi = 0; qi < S; ++qi) {
            int16_t m_prev = static_cast<int16_t>(-32768);
            uint32_t l_prev = 0;
            std::vector<int64_t> acc(D, 0);

            for (int kj = 0; kj < S; ++kj) {
                if (causal && kj > qi) {
                    if (hard_mask) {
                        continue;
                    }
                }

                int64_t dp = 0;
                for (int d = 0; d < D; ++d) {
                    dp += static_cast<int32_t>(Q[qi][d]) * static_cast<int32_t>(K[kj][d]);
                }
                int16_t dp_q8_8 = static_cast<int16_t>((dp >> 8) & 0xFFFF);
                int16_t score = q8_8_mul_sat(dp_q8_8, scale_q8_8);
                if (causal && kj > qi && !hard_mask) {
                    score = neg_large;
                }

                int16_t m_new = (score > m_prev) ? score : m_prev;
                int16_t diff_old = static_cast<int16_t>(m_prev - m_new);
                int16_t diff_new = static_cast<int16_t>(score - m_new);

                uint16_t exp_old = exp_real_q1_15(diff_old);
                uint16_t exp_new = exp_real_q1_15(diff_new);

                uint32_t l_scaled = static_cast<uint32_t>((static_cast<uint64_t>(l_prev) * exp_old) >> 15);
                uint32_t l_term = static_cast<uint32_t>(exp_new) << 1;
                l_prev = to_u32(static_cast<uint64_t>(l_scaled) + l_term);

                for (int d = 0; d < D; ++d) {
                    int64_t acc_old = (acc[d] * static_cast<int64_t>(exp_old)) >> 15;
                    int64_t pv_term = (static_cast<int64_t>(exp_new) * static_cast<int64_t>(static_cast<int32_t>(V[kj][d]))) << 1;
                    acc[d] = acc_old + pv_term;
                }
                m_prev = m_new;
            }

            for (int d = 0; d < D; ++d) {
                O[qi][d] = div_round_sat_s16(acc[d], l_prev);
            }
        }
        return O;
    }

    const int16_t scale_q8_8 = static_cast<int16_t>(std::lround((1.0 / std::sqrt(static_cast<double>(D))) * 256.0));
    const bool strict_rtl_mode = (mode == Mode::RTL_STRICT);
    const bool ctx_step_mode = (mode == Mode::RTL_CTX_STEP);
    const bool ctx_step_acc24_mode = (mode == Mode::RTL_CTX_STEP_ACC24);
    const bool ctx_interp_mode = (mode == Mode::RTL_CTX_INTERP);
    const bool ctx_pwl_mode = (mode == Mode::RTL_CTX_PWL);
    const bool ctx_realexp_mode = (mode == Mode::RTL_CTX_REAL_EXP);
    const bool ctx_like_mode = ctx_step_mode || ctx_step_acc24_mode || ctx_interp_mode || ctx_pwl_mode || ctx_realexp_mode;
    const bool acc_float_mode = (mode == Mode::ACC_FLOAT_QOUT || mode == Mode::ACC_FLOAT_REAL_EXP_QOUT);
    const bool hiacc_fixed_mode = (mode == Mode::FIXED_HIACC_QOUT || mode == Mode::FIXED_HIACC_REAL_EXP_QOUT);

    for (int qt = 0; qt < S / TQ; ++qt) {
        int q_start = qt * TQ;
        std::vector<int16_t> row_m(TQ, neg_large);
        std::vector<uint32_t> row_l(TQ, 0);
        std::vector<std::vector<int32_t>> row_acc(TQ, std::vector<int32_t>(D, 0));
        std::vector<std::vector<int64_t>> row_acc_hi(TQ, std::vector<int64_t>(D, 0));
        std::vector<std::vector<int64_t>> row_acc_rtl(TQ, std::vector<int64_t>(D, 0));
        std::vector<float> row_lf(TQ, 0.0f);
        std::vector<std::vector<float>> row_accf(TQ, std::vector<float>(D, 0.0f));

        for (int kt = 0; kt < S / TK; ++kt) {
            int k_start = kt * TK;
            for (int qi = 0; qi < TQ; ++qi) {
                for (int kj = 0; kj < TK; ++kj) {
                    int global_i = q_start + qi;
                    int global_j = k_start + kj;
                    int64_t dp = 0;
                    for (int d = 0; d < D; ++d) {
                        dp += static_cast<int32_t>(Q[global_i][d]) * static_cast<int32_t>(K[global_j][d]);
                    }
                    int16_t dp_q8_8 = static_cast<int16_t>((dp >> 8) & 0xFFFF);
                    int16_t score = q8_8_mul_sat(dp_q8_8, scale_q8_8);
                    if (causal && global_j > global_i) {
                        if (hard_mask) {
                            continue;
                        }
                        score = neg_large;
                    }

                    int16_t m_old = row_m[qi];
                    int16_t m_new = (score > m_old) ? score : m_old;
                    int16_t diff_old = static_cast<int16_t>(m_old - m_new);
                    int16_t diff_new = static_cast<int16_t>(score - m_new);

                    uint16_t exp_old;
                    uint16_t exp_new;
                    if (ctx_step_mode || ctx_step_acc24_mode) {
                        exp_old = exp2_ctx_step_q1_15(diff_old);
                        exp_new = exp2_ctx_step_q1_15(diff_new);
                    } else if (ctx_interp_mode) {
                        exp_old = exp2_ctx_interp_q1_15(diff_old);
                        exp_new = exp2_ctx_interp_q1_15(diff_new);
                    } else if (ctx_pwl_mode) {
                        exp_old = exp_pwl_q1_15(diff_old);
                        exp_new = exp_pwl_q1_15(diff_new);
                    } else if (ctx_realexp_mode) {
                        exp_old = exp_real_q1_15(diff_old);
                        exp_new = exp_real_q1_15(diff_new);
                    } else {
                        bool use_pwl_exp = (mode == Mode::RTL_STRICT || mode == Mode::RTL_EXACT || mode == Mode::FLOAT_ONLINE_Q8 || mode == Mode::ACC_FLOAT_QOUT || mode == Mode::FIXED_HIACC_QOUT);
                        exp_old = use_pwl_exp ? exp_pwl_q1_15(diff_old) : exp_real_q1_15(diff_old);
                        exp_new = use_pwl_exp ? exp_pwl_q1_15(diff_new) : exp_real_q1_15(diff_new);
                    }

                    if (strict_rtl_mode) {
                        uint32_t l_scaled = (static_cast<uint64_t>(row_l[qi]) * exp_old) >> 15;
                        uint32_t l_term = (static_cast<uint32_t>(exp_new) << 1);
                        row_l[qi] = to_u32(static_cast<uint64_t>(l_scaled) + l_term);

                        for (int d = 0; d < D; ++d) {
                            int64_t acc_old_sc = (row_acc_rtl[qi][d] * static_cast<int64_t>(exp_old)) >> 15;
                            int64_t pv_term = (static_cast<int64_t>(exp_new) * static_cast<int64_t>(static_cast<int32_t>(V[global_j][d]))) << 1;
                            row_acc_rtl[qi][d] = acc_old_sc + pv_term;
                        }
                    } else if (ctx_like_mode) {
                        uint32_t l_scaled = (static_cast<uint64_t>(row_l[qi]) * exp_old) >> 15;
                        uint32_t l_term = (static_cast<uint32_t>(exp_new) << 1);
                        row_l[qi] = to_u32(static_cast<uint64_t>(l_scaled) + l_term);

                        for (int d = 0; d < D; ++d) {
                            int64_t acc_old_sc = (static_cast<int64_t>(row_acc[qi][d]) * exp_old) >> 15;
                            int64_t pv_term = (static_cast<int64_t>(exp_new) * static_cast<int64_t>(static_cast<int32_t>(V[global_j][d]))) >> 7;
                            row_acc[qi][d] = to_s32(acc_old_sc + pv_term);
                        }
                    } else if (acc_float_mode) {
                        float exp_old_f = static_cast<float>(exp_old) / 32768.0f;
                        float exp_new_f = static_cast<float>(exp_new) / 32768.0f;
                        row_lf[qi] = row_lf[qi] * exp_old_f + exp_new_f;
                        for (int d = 0; d < D; ++d) {
                            row_accf[qi][d] = row_accf[qi][d] * exp_old_f + exp_new_f * q8_8_to_float(V[global_j][d]);
                        }
                    } else if (hiacc_fixed_mode) {
                        uint32_t l_scaled = (static_cast<uint64_t>(row_l[qi]) * exp_old) >> 15;
                        uint32_t l_term = (static_cast<uint32_t>(exp_new) << 1);
                        row_l[qi] = to_u32(static_cast<uint64_t>(l_scaled) + l_term);

                        for (int d = 0; d < D; ++d) {
                            int64_t acc_old_sc = (row_acc_hi[qi][d] * static_cast<int64_t>(exp_old)) >> 15;
                            int64_t pv_term = (static_cast<int64_t>(exp_new) * static_cast<int64_t>(static_cast<int32_t>(V[global_j][d]))) << 1;
                            row_acc_hi[qi][d] = acc_old_sc + pv_term;
                        }
                    } else {
                        uint32_t l_scaled = (static_cast<uint64_t>(row_l[qi]) * exp_old) >> 15;
                        uint32_t l_term = (static_cast<uint32_t>(exp_new) << 1);
                        row_l[qi] = to_u32(static_cast<uint64_t>(l_scaled) + l_term);

                        for (int d = 0; d < D; ++d) {
                            int64_t acc_old_sc = (static_cast<int64_t>(row_acc[qi][d]) * exp_old) >> 15;
                            int64_t pv_term = (static_cast<int64_t>(exp_new) * static_cast<int32_t>(V[global_j][d])) >> 7;
                            row_acc[qi][d] = to_s32(acc_old_sc + pv_term);
                        }
                    }

                    row_m[qi] = m_new;
                }
            }
        }

        for (int qi = 0; qi < TQ; ++qi) {
            if (strict_rtl_mode) {
                uint32_t recip = recip_nr_rtl_q16_16(row_l[qi]);
                for (int d = 0; d < D; ++d) {
                    int64_t num = row_acc_rtl[qi][d];
                    __int128 norm_mul_q32_32 = static_cast<__int128>(num) * static_cast<int64_t>(static_cast<int32_t>(recip));
                    __int128 norm_rounded_q32_32 = (norm_mul_q32_32 >= 0)
                        ? (norm_mul_q32_32 + static_cast<__int128>(2147483648ll))
                        : (norm_mul_q32_32 - static_cast<__int128>(2147483648ll));
                    int64_t norm_result = static_cast<int64_t>(norm_rounded_q32_32 >> 32);
                    if (norm_result > 32767) O[q_start + qi][d] = 32767;
                    else if (norm_result < -32768) O[q_start + qi][d] = -32768;
                    else O[q_start + qi][d] = static_cast<int16_t>(norm_result);
                }
            } else if (ctx_like_mode) {
                uint32_t recip = recip_nr_rtl_q16_16(row_l[qi]);
                for (int d = 0; d < D; ++d) {
                    int64_t num = static_cast<int64_t>(row_acc[qi][d]);
                    if (ctx_step_acc24_mode) num <<= 8;
                    __int128 norm_mul_q32_32 = static_cast<__int128>(num) * static_cast<int64_t>(static_cast<int32_t>(recip));
                    __int128 norm_rounded_q32_32 = (norm_mul_q32_32 >= 0)
                        ? (norm_mul_q32_32 + static_cast<__int128>(2147483648ll))
                        : (norm_mul_q32_32 - static_cast<__int128>(2147483648ll));
                    int64_t norm_result = static_cast<int64_t>(norm_rounded_q32_32 >> 32);
                    if (norm_result > 32767) O[q_start + qi][d] = 32767;
                    else if (norm_result < -32768) O[q_start + qi][d] = -32768;
                    else O[q_start + qi][d] = static_cast<int16_t>(norm_result);
                }
            } else if (acc_float_mode) {
                float l = row_lf[qi];
                if (l <= 1e-20f) l = 1e-20f;
                for (int d = 0; d < D; ++d) {
                    O[q_start + qi][d] = float_to_q8_8(row_accf[qi][d] / l);
                }
            } else if (hiacc_fixed_mode) {
                uint32_t l = row_l[qi];
                for (int d = 0; d < D; ++d) {
                    O[q_start + qi][d] = div_round_sat_s16(row_acc_hi[qi][d], l);
                }
            } else if (mode == Mode::RTL_REAL_EXP_FLOAT_NORM || mode == Mode::FLOAT_ONLINE_Q8) {
                float l = static_cast<float>(row_l[qi]) / 65536.0f;
                if (l <= 1e-20f) l = 1e-20f;
                for (int d = 0; d < D; ++d) {
                    float acc = static_cast<float>(row_acc[qi][d]) / 256.0f;
                    O[q_start + qi][d] = float_to_q8_8(acc / l);
                }
            } else {
                uint32_t recip = recip_q16_16(row_l[qi]);
                for (int d = 0; d < D; ++d) {
                    int64_t norm_mul = static_cast<int64_t>(row_acc[qi][d]) * static_cast<int64_t>(static_cast<int32_t>(recip));
                    int32_t norm = static_cast<int32_t>(norm_mul >> 16);
                    O[q_start + qi][d] = sat_s16(norm);
                }
            }
        }
    }

    return O;
}

} // namespace attn
