#include "attention_core.hpp"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <random>
#include <stdexcept>

namespace attn {

namespace {

struct StageAccum {
    double abs_sum = 0.0;
    double sq_sum = 0.0;
    double max_abs = 0.0;
    int64_t n = 0;

    void add(double e) {
        double ae = std::fabs(e);
        abs_sum += ae;
        sq_sum += ae * ae;
        max_abs = std::max(max_abs, ae);
        ++n;
    }

    StageMetrics done() const {
        StageMetrics m;
        if (n <= 0) return m;
        m.mae = abs_sum / static_cast<double>(n);
        m.maxe = max_abs;
        m.rmse = std::sqrt(sq_sum / static_cast<double>(n));
        return m;
    }
};

MatrixU16 random_bf16_uniform(int S, int D, std::mt19937& rng, float low, float high) {
    std::uniform_real_distribution<float> ud(low, high);
    MatrixU16 out(S, std::vector<uint16_t>(D, 0));
    for (int i = 0; i < S; ++i) {
        for (int d = 0; d < D; ++d) {
            uint32_t bits = f32_to_bits(ud(rng));
            out[i][d] = fp32_to_bf16_bits(bits);
        }
    }
    return out;
}

MatrixF bf16_to_float_matrix(const MatrixU16& x) {
    MatrixF out(x.size(), std::vector<float>(x[0].size(), 0.0f));
    for (size_t i = 0; i < x.size(); ++i) {
        for (size_t d = 0; d < x[0].size(); ++d) {
            out[i][d] = bits_to_f32(bf16_to_fp32_bits(x[i][d]));
        }
    }
    return out;
}

MatrixU16 fp32_to_bf16_matrix(const MatrixF& x) {
    MatrixU16 out(x.size(), std::vector<uint16_t>(x[0].size(), 0));
    for (size_t i = 0; i < x.size(); ++i) {
        for (size_t d = 0; d < x[0].size(); ++d) {
            out[i][d] = fp32_to_bf16_bits(f32_to_bits(x[i][d]));
        }
    }
    return out;
}

struct CycleModelCfg {
    std::string name;
    int dot_lanes = 4;
    int dp_init_cycles = 1;
    int post_cycles = 3;
    bool overlap_dp_post = false;
    int rows_parallel = 1;
    int norm_vec = 1;
    int noc_dispatch_per_k = 0;
    int noc_row_sync = 0;
};

ComputeCycleResult simulate_compute_cycles(const Config& cfg, const CycleModelCfg& m) {
    ComputeCycleResult r;
    r.name = m.name;
    r.pair_total = static_cast<int64_t>(cfg.S) * static_cast<int64_t>(cfg.S);

    const int rows_par = std::max(1, m.rows_parallel);
    const int norm_vec = std::max(1, m.norm_vec);
    const int lanes = std::max(1, m.dot_lanes);

    const int dp_cycles = m.dp_init_cycles + (cfg.D + lanes - 1) / lanes;
    const int post_cycles = std::max(1, m.post_cycles);
    const int steady = m.overlap_dp_post ? std::max(dp_cycles, post_cycles) : (dp_cycles + post_cycles);
    const int startup = m.overlap_dp_post ? (dp_cycles + post_cycles - 1) : (dp_cycles + post_cycles);

    const int64_t rows_total = cfg.S;
    const int64_t row_groups = (rows_total + rows_par - 1) / rows_par;
    const int64_t per_row_cycles = startup + static_cast<int64_t>(cfg.S - 1) * steady;
    r.compute_cycles = row_groups * per_row_cycles;

    r.norm_cycles = (static_cast<int64_t>(cfg.S) * cfg.D + norm_vec - 1) / norm_vec;
    r.noc_cycles = row_groups * (static_cast<int64_t>(cfg.S) * m.noc_dispatch_per_k + m.noc_row_sync);
    r.total_compute_only_cycles = r.compute_cycles + r.norm_cycles + r.noc_cycles;
    r.pair_throughput_cycles = static_cast<double>(r.compute_cycles) / static_cast<double>(r.pair_total);
    return r;
}

} // namespace

Metrics calc_metrics(const MatrixF& a, const MatrixF& b) {
    Metrics m;
    int64_t n = 0;
    double mse = 0.0;
    for (size_t i = 0; i < a.size(); ++i) {
        for (size_t d = 0; d < a[0].size(); ++d) {
            double e = std::fabs(static_cast<double>(a[i][d]) - static_cast<double>(b[i][d]));
            m.mae += e;
            mse += e * e;
            if (e > m.maxe) {
                m.maxe = e;
                m.max_i = static_cast<int>(i);
                m.max_d = static_cast<int>(d);
            }
            ++n;
        }
    }
    m.mae /= static_cast<double>(n);
    m.rmse = std::sqrt(mse / static_cast<double>(n));
    return m;
}

std::vector<ModeResult> run_one_seed_bf16(const Config& cfg, int seed) {
    std::mt19937 rng(seed);
    MatrixU16 q_bf16 = random_bf16_uniform(cfg.S, cfg.D, rng, cfg.bf16_low, cfg.bf16_high);
    MatrixU16 k_bf16 = random_bf16_uniform(cfg.S, cfg.D, rng, cfg.bf16_low, cfg.bf16_high);
    MatrixU16 v_bf16 = random_bf16_uniform(cfg.S, cfg.D, rng, cfg.bf16_low, cfg.bf16_high);

    MatrixF qf = bf16_to_float_matrix(q_bf16);
    MatrixF kf = bf16_to_float_matrix(k_bf16);
    MatrixF vf = bf16_to_float_matrix(v_bf16);

    MatrixF fp32_ref = direct_sdpa_fp32(qf, kf, vf, cfg.causal);
    MatrixU16 fp32_ref_bf16 = fp32_to_bf16_matrix(fp32_ref);

    uint32_t scale_bits = f32_to_bits(1.0f / std::sqrt(static_cast<float>(cfg.D)));
    uint32_t neg_large_bits = f32_to_bits(cfg.neg_large_fp32);

    MatrixU16 rtl_out = online_rtl_like_bf16_fp32(q_bf16, k_bf16, v_bf16, cfg.TQ, cfg.TK,
                                                 cfg.causal, scale_bits, neg_large_bits);
    MatrixU16 ref_out = attention_bf16_fp32_reference(q_bf16, k_bf16, v_bf16, cfg.TQ, cfg.TK,
                                                      cfg.causal, scale_bits, neg_large_bits);

    MatrixF rtl_out_f = bf16_to_float_matrix(rtl_out);
    MatrixF ref_out_f = bf16_to_float_matrix(ref_out);
    MatrixF fp32_ref_bf16_f = bf16_to_float_matrix(fp32_ref_bf16);

    std::vector<ModeResult> out;
    out.push_back({"rtl_bf16_fp32", calc_metrics(rtl_out_f, ref_out_f)});
    out.push_back({"bf16_ref_vs_fp32", calc_metrics(ref_out_f, fp32_ref)});
    out.push_back({"fp32_then_bf16", calc_metrics(fp32_ref_bf16_f, fp32_ref)});
    return out;
}

std::vector<ModeResult> run_one_seed(const Config& cfg, int seed) {
    if (cfg.input_mode == "bf16" || cfg.input_mode == "bf16-uniform") {
        return run_one_seed_bf16(cfg, seed);
    }
    std::mt19937 rng(seed);
    MatrixI16 q_q(cfg.S, std::vector<int16_t>(cfg.D, 0));
    MatrixI16 k_q(cfg.S, std::vector<int16_t>(cfg.D, 0));
    MatrixI16 v_q(cfg.S, std::vector<int16_t>(cfg.D, 0));

    if (cfg.input_mode == "small-int") {
        std::uniform_int_distribution<int> ud(-32, 31);
        for (int i = 0; i < cfg.S; ++i) for (int d = 0; d < cfg.D; ++d) q_q[i][d] = static_cast<int16_t>(ud(rng));
        for (int i = 0; i < cfg.S; ++i) for (int d = 0; d < cfg.D; ++d) k_q[i][d] = static_cast<int16_t>(ud(rng));
        for (int i = 0; i < cfg.S; ++i) for (int d = 0; d < cfg.D; ++d) v_q[i][d] = static_cast<int16_t>(ud(rng));
    } else if (cfg.input_mode == "gaussian") {
        std::normal_distribution<float> nd(0.0f, 1.0f);
        MatrixF qf(cfg.S, std::vector<float>(cfg.D, 0.0f));
        MatrixF kf(cfg.S, std::vector<float>(cfg.D, 0.0f));
        MatrixF vf(cfg.S, std::vector<float>(cfg.D, 0.0f));
        for (int i = 0; i < cfg.S; ++i) for (int d = 0; d < cfg.D; ++d) qf[i][d] = nd(rng);
        for (int i = 0; i < cfg.S; ++i) for (int d = 0; d < cfg.D; ++d) kf[i][d] = nd(rng);
        for (int i = 0; i < cfg.S; ++i) for (int d = 0; d < cfg.D; ++d) vf[i][d] = nd(rng);
        q_q = quant_q8_8(qf);
        k_q = quant_q8_8(kf);
        v_q = quant_q8_8(vf);
    } else {
        throw std::runtime_error("Unknown --input-mode, use small-int|gaussian|bf16");
    }

    MatrixF q_qf = dequant_q8_8(q_q);
    MatrixF k_qf = dequant_q8_8(k_q);
    MatrixF v_qf = dequant_q8_8(v_q);

    MatrixF fp32_ref = direct_sdpa_fp32(q_qf, k_qf, v_qf, cfg.causal);

    bool hard_mask = (cfg.mask_mode == "hard");
    int16_t neg_large = static_cast<int16_t>(cfg.neg_large_q8_8);

    MatrixF rtl_strict_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::RTL_STRICT, neg_large, hard_mask));
    MatrixF rtl_ctx_step_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::RTL_CTX_STEP, neg_large, hard_mask));
    MatrixF rtl_ctx_step_acc24_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::RTL_CTX_STEP_ACC24, neg_large, hard_mask));
    MatrixF rtl_ctx_interp_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::RTL_CTX_INTERP, neg_large, hard_mask));
    MatrixF rtl_ctx_pwl_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::RTL_CTX_PWL, neg_large, hard_mask));
    MatrixF rtl_ctx_realexp_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::RTL_CTX_REAL_EXP, neg_large, hard_mask));
    MatrixF rtl_exact_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::RTL_EXACT, neg_large, hard_mask));
    MatrixF rtl_realexp_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::RTL_REAL_EXP, neg_large, hard_mask));
    MatrixF rtl_realexp_floatnorm_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::RTL_REAL_EXP_FLOAT_NORM, neg_large, hard_mask));
    MatrixF float_online_q8_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::FLOAT_ONLINE_Q8, neg_large, hard_mask));
    MatrixF acc_float_qout_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::ACC_FLOAT_QOUT, neg_large, hard_mask));
    MatrixF acc_float_real_exp_qout_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::ACC_FLOAT_REAL_EXP_QOUT, neg_large, hard_mask));
    MatrixF fixed_hiacc_qout_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::FIXED_HIACC_QOUT, neg_large, hard_mask));
    MatrixF fixed_hiacc_real_exp_qout_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::FIXED_HIACC_REAL_EXP_QOUT, neg_large, hard_mask));
    MatrixF fp32_then_q8_f = dequant_q8_8(quant_q8_8(fp32_ref));

    std::vector<ModeResult> out;
    out.push_back({"rtl_strict", calc_metrics(rtl_strict_f, fp32_ref)});
    out.push_back({"rtl_ctx_step", calc_metrics(rtl_ctx_step_f, fp32_ref)});
    out.push_back({"rtl_ctx_step_acc24", calc_metrics(rtl_ctx_step_acc24_f, fp32_ref)});
    out.push_back({"rtl_ctx_interp", calc_metrics(rtl_ctx_interp_f, fp32_ref)});
    out.push_back({"rtl_ctx_pwl", calc_metrics(rtl_ctx_pwl_f, fp32_ref)});
    out.push_back({"rtl_ctx_real_exp", calc_metrics(rtl_ctx_realexp_f, fp32_ref)});
    out.push_back({"rtl_exact", calc_metrics(rtl_exact_f, fp32_ref)});
    out.push_back({"rtl_real_exp", calc_metrics(rtl_realexp_f, fp32_ref)});
    out.push_back({"rtl_real_exp_float_norm", calc_metrics(rtl_realexp_floatnorm_f, fp32_ref)});
    out.push_back({"float_online_q8", calc_metrics(float_online_q8_f, fp32_ref)});
    out.push_back({"acc_float_qout", calc_metrics(acc_float_qout_f, fp32_ref)});
    out.push_back({"acc_float_real_exp_qout", calc_metrics(acc_float_real_exp_qout_f, fp32_ref)});
    out.push_back({"fixed_hiacc_qout", calc_metrics(fixed_hiacc_qout_f, fp32_ref)});
    out.push_back({"fixed_hiacc_real_exp_qout", calc_metrics(fixed_hiacc_real_exp_qout_f, fp32_ref)});
    out.push_back({"fp32_then_q8", calc_metrics(fp32_then_q8_f, fp32_ref)});
    return out;
}

StageDecompResult run_stage_decomposition_bf16(const Config& cfg, int seed) {
    std::mt19937 rng(seed);
    MatrixU16 q_bf16 = random_bf16_uniform(cfg.S, cfg.D, rng, cfg.bf16_low, cfg.bf16_high);
    MatrixU16 k_bf16 = random_bf16_uniform(cfg.S, cfg.D, rng, cfg.bf16_low, cfg.bf16_high);
    MatrixU16 v_bf16 = random_bf16_uniform(cfg.S, cfg.D, rng, cfg.bf16_low, cfg.bf16_high);

    uint32_t scale_bits = f32_to_bits(1.0f / std::sqrt(static_cast<float>(cfg.D)));
    uint32_t neg_large_bits = f32_to_bits(cfg.neg_large_fp32);

    StageAccum dot_acc;
    StageAccum score_acc;
    StageAccum exp_acc;
    StageAccum l_acc;
    StageAccum acc_acc;
    StageAccum norm_acc;

    for (int qt = 0; qt < cfg.S / cfg.TQ; ++qt) {
        int q_start = qt * cfg.TQ;
        std::vector<uint32_t> m_ref(cfg.TQ, 0u);
        std::vector<uint32_t> l_ref(cfg.TQ, 0u);
        std::vector<std::vector<uint32_t>> acc_ref(cfg.TQ, std::vector<uint32_t>(cfg.D, 0u));

        std::vector<uint32_t> m_rtl(cfg.TQ, 0u);
        std::vector<uint32_t> l_rtl(cfg.TQ, 0u);
        std::vector<std::vector<uint32_t>> acc_rtl(cfg.TQ, std::vector<uint32_t>(cfg.D, 0u));

        for (int kt = 0; kt < cfg.S / cfg.TK; ++kt) {
            int k_start = kt * cfg.TK;
            for (int qi = 0; qi < cfg.TQ; ++qi) {
                for (int kj = 0; kj < cfg.TK; ++kj) {
                    int gi = q_start + qi;
                    int gj = k_start + kj;
                    bool row_start = (kt == 0) && (kj == 0);

                    uint32_t dot_ref = 0u;
                    uint32_t dot_rtl = 0u;
                    for (int d = 0; d < cfg.D; ++d) {
                        uint32_t prod_bits = fp32_mul_q16_bits(bf16_to_fp32_bits(q_bf16[gi][d]),
                                                               bf16_to_fp32_bits(k_bf16[gj][d]));
                        dot_ref = fp32_add_ref_bits(dot_ref, prod_bits);
                        dot_rtl = fp32_add_rtl_bits(dot_rtl, prod_bits);
                    }
                    dot_acc.add(static_cast<double>(bits_to_f32(dot_rtl) - bits_to_f32(dot_ref)));

                    uint32_t score_ref = fp32_mul_q16_bits(dot_ref, scale_bits);
                    uint32_t score_rtl = fp32_mul_q16_bits(dot_rtl, scale_bits);
                    if (cfg.causal && (gj > gi)) {
                        score_ref = neg_large_bits;
                        score_rtl = neg_large_bits;
                    }
                    score_acc.add(static_cast<double>(bits_to_f32(score_rtl) - bits_to_f32(score_ref)));

                    uint32_t m_new_ref = row_start
                        ? score_ref
                        : ((bits_to_f32(score_ref) > bits_to_f32(m_ref[qi])) ? score_ref : m_ref[qi]);
                    uint32_t diff_old_ref = fp32_add_ref_bits(m_ref[qi], fp32_neg_bits(m_new_ref));
                    uint32_t diff_new_ref = fp32_add_ref_bits(score_ref, fp32_neg_bits(m_new_ref));
                    uint32_t exp_old_ref = row_start ? 0u : f32_to_bits(std::exp2(bits_to_f32(diff_old_ref)));
                    uint32_t exp_new_ref = row_start ? 0x3F800000u : f32_to_bits(std::exp2(bits_to_f32(diff_new_ref)));

                    uint32_t m_new_rtl = row_start ? score_rtl : fp32_max_bits(score_rtl, m_rtl[qi]);
                    uint32_t diff_old_rtl = fp32_add_rtl_bits(m_rtl[qi], fp32_neg_bits(m_new_rtl));
                    uint32_t diff_new_rtl = fp32_add_rtl_bits(score_rtl, fp32_neg_bits(m_new_rtl));
                    uint32_t exp_old_rtl = row_start ? 0u : fp32_exp2_pwl_bits(diff_old_rtl);
                    uint32_t exp_new_rtl = row_start ? 0x3F800000u : fp32_exp2_pwl_bits(diff_new_rtl);

                    exp_acc.add(static_cast<double>(bits_to_f32(exp_old_rtl) - bits_to_f32(exp_old_ref)));
                    exp_acc.add(static_cast<double>(bits_to_f32(exp_new_rtl) - bits_to_f32(exp_new_ref)));

                    uint32_t l_scaled_ref = row_start ? 0u
                        : f32_to_bits(bits_to_f32(l_ref[qi]) * bits_to_f32(exp_old_ref));
                    uint32_t l_new_ref = fp32_add_ref_bits(l_scaled_ref, exp_new_ref);

                    uint32_t l_scaled_rtl = fp32_mul_q16_bits(l_rtl[qi], exp_old_rtl);
                    uint32_t l_new_rtl = fp32_add_rtl_bits(row_start ? 0u : l_scaled_rtl, exp_new_rtl);
                    l_acc.add(static_cast<double>(bits_to_f32(l_new_rtl) - bits_to_f32(l_new_ref)));

                    for (int d = 0; d < cfg.D; ++d) {
                        uint32_t acc_scaled_ref = row_start ? 0u : fp32_mul_q16_bits(acc_ref[qi][d], exp_old_ref);
                        uint32_t v_term_ref = fp32_mul_q16_bits(bf16_to_fp32_bits(v_bf16[gj][d]), exp_new_ref);
                        uint32_t acc_new_ref = fp32_add_ref_bits(acc_scaled_ref, v_term_ref);

                        uint32_t acc_scaled_rtl = fp32_mul_q16_bits(acc_rtl[qi][d], exp_old_rtl);
                        uint32_t v_term_rtl = fp32_mul_q16_bits(bf16_to_fp32_bits(v_bf16[gj][d]), exp_new_rtl);
                        uint32_t acc_new_rtl = fp32_add_rtl_bits(row_start ? 0u : acc_scaled_rtl, v_term_rtl);

                        acc_acc.add(static_cast<double>(bits_to_f32(acc_new_rtl) - bits_to_f32(acc_new_ref)));
                        acc_ref[qi][d] = acc_new_ref;
                        acc_rtl[qi][d] = acc_new_rtl;
                    }

                    m_ref[qi] = m_new_ref;
                    m_rtl[qi] = m_new_rtl;
                    l_ref[qi] = l_new_ref;
                    l_rtl[qi] = l_new_rtl;
                }
            }
        }

        for (int qi = 0; qi < cfg.TQ; ++qi) {
            float l_ref_f = bits_to_f32(l_ref[qi]);
            uint32_t inv_l_ref = (l_ref_f == 0.0f) ? 0u : f32_to_bits(1.0f / l_ref_f);
            uint32_t inv_l_rtl = fp32_recip_bits(l_rtl[qi]);
            for (int d = 0; d < cfg.D; ++d) {
                uint32_t out_ref = fp32_mul_q16_bits(acc_ref[qi][d], inv_l_ref);
                uint32_t out_rtl = fp32_mul_q16_bits(acc_rtl[qi][d], inv_l_rtl);
                norm_acc.add(static_cast<double>(bits_to_f32(out_rtl) - bits_to_f32(out_ref)));
            }
        }
    }

    StageDecompResult r;
    r.dot = dot_acc.done();
    r.score = score_acc.done();
    r.exp = exp_acc.done();
    r.l = l_acc.done();
    r.acc = acc_acc.done();
    r.norm = norm_acc.done();
    return r;
}

ModuleEvalResult run_module_error_eval_bf16(const Config& cfg, int seed) {
    std::mt19937 rng(seed);
    MatrixU16 q_bf16 = random_bf16_uniform(cfg.S, cfg.D, rng, cfg.bf16_low, cfg.bf16_high);
    MatrixU16 k_bf16 = random_bf16_uniform(cfg.S, cfg.D, rng, cfg.bf16_low, cfg.bf16_high);
    MatrixU16 v_bf16 = random_bf16_uniform(cfg.S, cfg.D, rng, cfg.bf16_low, cfg.bf16_high);

    uint32_t scale_bits = f32_to_bits(1.0f / std::sqrt(static_cast<float>(cfg.D)));
    uint32_t neg_large_bits = f32_to_bits(cfg.neg_large_fp32);

    StageAccum add_acc;
    StageAccum mul_acc;
    StageAccum exp_acc;
    StageAccum recip_acc;
    StageAccum bf16_acc;

    for (int qt = 0; qt < cfg.S / cfg.TQ; ++qt) {
        int q_start = qt * cfg.TQ;
        std::vector<uint32_t> row_m(cfg.TQ, 0u);
        std::vector<uint32_t> row_l(cfg.TQ, 0u);
        std::vector<std::vector<uint32_t>> row_acc(cfg.TQ, std::vector<uint32_t>(cfg.D, 0u));

        for (int kt = 0; kt < cfg.S / cfg.TK; ++kt) {
            int k_start = kt * cfg.TK;
            for (int qi = 0; qi < cfg.TQ; ++qi) {
                for (int kj = 0; kj < cfg.TK; ++kj) {
                    int gi = q_start + qi;
                    int gj = k_start + kj;
                    bool row_start = (kt == 0) && (kj == 0);

                    uint32_t dot = 0u;
                    for (int d = 0; d < cfg.D; ++d) {
                        uint32_t a_bits = bf16_to_fp32_bits(q_bf16[gi][d]);
                        uint32_t b_bits = bf16_to_fp32_bits(k_bf16[gj][d]);
                        uint32_t mul_rtl = fp32_mul_q16_bits(a_bits, b_bits);
                        uint32_t mul_ref = f32_to_bits(bits_to_f32(a_bits) * bits_to_f32(b_bits));
                        mul_acc.add(static_cast<double>(bits_to_f32(mul_rtl) - bits_to_f32(mul_ref)));

                        uint32_t add_rtl = fp32_add_rtl_bits(dot, mul_rtl);
                        uint32_t add_ref = fp32_add_ref_bits(dot, mul_rtl);
                        add_acc.add(static_cast<double>(bits_to_f32(add_rtl) - bits_to_f32(add_ref)));
                        dot = add_rtl;
                    }

                    uint32_t score = fp32_mul_q16_bits(dot, scale_bits);
                    uint32_t score_ref = f32_to_bits(bits_to_f32(dot) * bits_to_f32(scale_bits));
                    mul_acc.add(static_cast<double>(bits_to_f32(score) - bits_to_f32(score_ref)));

                    if (cfg.causal && (gj > gi)) score = neg_large_bits;
                    uint16_t score_bf16 = fp32_to_bf16_bits(score);
                    uint16_t score_bf16_ref = fp32_to_bf16_bits(score);
                    bf16_acc.add(static_cast<double>(static_cast<int32_t>(score_bf16) - static_cast<int32_t>(score_bf16_ref)));

                    uint32_t score_fp32 = bf16_to_fp32_bits(score_bf16);
                    uint32_t m_new = row_start ? score_fp32 : fp32_max_bits(score_fp32, row_m[qi]);
                    uint32_t diff_old = fp32_add_rtl_bits(row_m[qi], fp32_neg_bits(m_new));
                    uint32_t diff_new = fp32_add_rtl_bits(score_fp32, fp32_neg_bits(m_new));

                    uint32_t exp_old = row_start ? 0u : fp32_exp2_pwl_bits(diff_old);
                    uint32_t exp_new = row_start ? 0x3F800000u : fp32_exp2_pwl_bits(diff_new);
                    uint32_t exp_old_ref = f32_to_bits(std::exp2(bits_to_f32(diff_old)));
                    uint32_t exp_new_ref = f32_to_bits(std::exp2(bits_to_f32(diff_new)));
                    exp_acc.add(static_cast<double>(bits_to_f32(exp_old) - bits_to_f32(exp_old_ref)));
                    exp_acc.add(static_cast<double>(bits_to_f32(exp_new) - bits_to_f32(exp_new_ref)));

                    uint32_t l_scaled = fp32_mul_q16_bits(row_l[qi], exp_old);
                    uint32_t l_scaled_ref = f32_to_bits(bits_to_f32(row_l[qi]) * bits_to_f32(exp_old));
                    mul_acc.add(static_cast<double>(bits_to_f32(l_scaled) - bits_to_f32(l_scaled_ref)));

                    uint32_t l_new = fp32_add_rtl_bits(row_start ? 0u : l_scaled, exp_new);
                    uint32_t l_new_ref = fp32_add_ref_bits(row_start ? 0u : l_scaled, exp_new);
                    add_acc.add(static_cast<double>(bits_to_f32(l_new) - bits_to_f32(l_new_ref)));
                    row_l[qi] = l_new;

                    uint32_t recip = fp32_recip_bits(row_l[qi]);
                    float l_val = bits_to_f32(row_l[qi]);
                    uint32_t recip_ref = (l_val == 0.0f) ? 0u : f32_to_bits(1.0f / l_val);
                    recip_acc.add(static_cast<double>(bits_to_f32(recip) - bits_to_f32(recip_ref)));

                    for (int d = 0; d < cfg.D; ++d) {
                        uint32_t acc_scaled = fp32_mul_q16_bits(row_acc[qi][d], exp_old);
                        uint32_t acc_scaled_ref = f32_to_bits(bits_to_f32(row_acc[qi][d]) * bits_to_f32(exp_old));
                        mul_acc.add(static_cast<double>(bits_to_f32(acc_scaled) - bits_to_f32(acc_scaled_ref)));

                        uint32_t v_bits = bf16_to_fp32_bits(v_bf16[gj][d]);
                        uint32_t v_term = fp32_mul_q16_bits(v_bits, exp_new);
                        uint32_t v_term_ref = f32_to_bits(bits_to_f32(v_bits) * bits_to_f32(exp_new));
                        mul_acc.add(static_cast<double>(bits_to_f32(v_term) - bits_to_f32(v_term_ref)));

                        uint32_t acc_new = fp32_add_rtl_bits(row_start ? 0u : acc_scaled, v_term);
                        uint32_t acc_new_ref = fp32_add_ref_bits(row_start ? 0u : acc_scaled, v_term);
                        add_acc.add(static_cast<double>(bits_to_f32(acc_new) - bits_to_f32(acc_new_ref)));
                        row_acc[qi][d] = acc_new;
                    }

                    row_m[qi] = m_new;
                }
            }
        }
    }

    ModuleEvalResult r;
    r.fp32_add = add_acc.done();
    r.fp32_mul_q16 = mul_acc.done();
    r.fp32_exp2_pwl = exp_acc.done();
    r.fp32_recip = recip_acc.done();
    r.fp32_to_bf16 = bf16_acc.done();
    return r;
}

StageDecompResult run_stage_decomposition(const Config& cfg, int seed) {
    if (cfg.input_mode == "bf16" || cfg.input_mode == "bf16-uniform") {
        return run_stage_decomposition_bf16(cfg, seed);
    }
    std::mt19937 rng(seed);
    MatrixI16 q_q(cfg.S, std::vector<int16_t>(cfg.D, 0));
    MatrixI16 k_q(cfg.S, std::vector<int16_t>(cfg.D, 0));
    MatrixI16 v_q(cfg.S, std::vector<int16_t>(cfg.D, 0));

    if (cfg.input_mode == "small-int") {
        std::uniform_int_distribution<int> ud(-32, 31);
        for (int i = 0; i < cfg.S; ++i) for (int d = 0; d < cfg.D; ++d) q_q[i][d] = static_cast<int16_t>(ud(rng));
        for (int i = 0; i < cfg.S; ++i) for (int d = 0; d < cfg.D; ++d) k_q[i][d] = static_cast<int16_t>(ud(rng));
        for (int i = 0; i < cfg.S; ++i) for (int d = 0; d < cfg.D; ++d) v_q[i][d] = static_cast<int16_t>(ud(rng));
    } else if (cfg.input_mode == "gaussian") {
        std::normal_distribution<float> nd(0.0f, 1.0f);
        MatrixF qf(cfg.S, std::vector<float>(cfg.D, 0.0f));
        MatrixF kf(cfg.S, std::vector<float>(cfg.D, 0.0f));
        MatrixF vf(cfg.S, std::vector<float>(cfg.D, 0.0f));
        for (int i = 0; i < cfg.S; ++i) for (int d = 0; d < cfg.D; ++d) qf[i][d] = nd(rng);
        for (int i = 0; i < cfg.S; ++i) for (int d = 0; d < cfg.D; ++d) kf[i][d] = nd(rng);
        for (int i = 0; i < cfg.S; ++i) for (int d = 0; d < cfg.D; ++d) vf[i][d] = nd(rng);
        q_q = quant_q8_8(qf);
        k_q = quant_q8_8(kf);
        v_q = quant_q8_8(vf);
    } else {
        throw std::runtime_error("Unknown --input-mode, use small-int|gaussian|bf16");
    }

    MatrixF qf = dequant_q8_8(q_q);
    MatrixF kf = dequant_q8_8(k_q);
    MatrixF vf = dequant_q8_8(v_q);

    const float scale_f = 1.0f / std::sqrt(static_cast<float>(cfg.D));
    const int16_t scale_q8_8 = static_cast<int16_t>(std::lround((1.0 / std::sqrt(static_cast<double>(cfg.D))) * 256.0));
    const bool hard_mask = (cfg.mask_mode == "hard");
    const int16_t neg_large = static_cast<int16_t>(cfg.neg_large_q8_8);

    StageAccum dot_acc;
    StageAccum score_acc;
    StageAccum exp_acc;
    StageAccum l_acc;
    StageAccum acc_acc;
    StageAccum norm_acc;

    for (int qt = 0; qt < cfg.S / cfg.TQ; ++qt) {
        int q_start = qt * cfg.TQ;
        std::vector<float> m_ref(cfg.TQ, -1e30f);
        std::vector<float> l_ref(cfg.TQ, 0.0f);
        std::vector<std::vector<float>> acc_ref(cfg.TQ, std::vector<float>(cfg.D, 0.0f));

        std::vector<int16_t> m_rtl(cfg.TQ, neg_large);
        std::vector<uint32_t> l_rtl(cfg.TQ, 0);
        std::vector<std::vector<int32_t>> acc_rtl(cfg.TQ, std::vector<int32_t>(cfg.D, 0));

        for (int kt = 0; kt < cfg.S / cfg.TK; ++kt) {
            int k_start = kt * cfg.TK;
            for (int qi = 0; qi < cfg.TQ; ++qi) {
                for (int kj = 0; kj < cfg.TK; ++kj) {
                    int i = q_start + qi;
                    int j = k_start + kj;

                    float dot_f = 0.0f;
                    int64_t dot_q = 0;
                    for (int d = 0; d < cfg.D; ++d) {
                        dot_f += qf[i][d] * kf[j][d];
                        dot_q += static_cast<int32_t>(q_q[i][d]) * static_cast<int32_t>(k_q[j][d]);
                    }
                    int16_t dot_q8_8 = static_cast<int16_t>((dot_q >> 8) & 0xFFFF);
                    float dot_qf = q8_8_to_float(dot_q8_8);
                    dot_acc.add(static_cast<double>(dot_qf - dot_f));

                    float score_f = dot_f * scale_f;
                    int16_t score_q = q8_8_mul_sat(dot_q8_8, scale_q8_8);
                    float score_qf = q8_8_to_float(score_q);

                    if (cfg.causal && j > i) {
                        if (hard_mask) {
                            continue;
                        }
                        score_f = static_cast<float>(cfg.neg_large_q8_8) / 256.0f;
                        score_q = neg_large;
                        score_qf = q8_8_to_float(score_q);
                    }
                    score_acc.add(static_cast<double>(score_qf - score_f));

                    float m_old_f = m_ref[qi];
                    float m_new_f = std::max(m_old_f, score_f);
                    float diff_old_f = m_old_f - m_new_f;
                    float diff_new_f = score_f - m_new_f;
                    float exp_old_f = std::exp(diff_old_f);
                    float exp_new_f = std::exp(diff_new_f);

                    int16_t m_old_q = m_rtl[qi];
                    int16_t m_new_q = (score_q > m_old_q) ? score_q : m_old_q;
                    int16_t diff_old_q = static_cast<int16_t>(m_old_q - m_new_q);
                    int16_t diff_new_q = static_cast<int16_t>(score_q - m_new_q);
                    uint16_t exp_old_q = exp_pwl_q1_15(diff_old_q);
                    uint16_t exp_new_q = exp_pwl_q1_15(diff_new_q);
                    float exp_old_qf = static_cast<float>(exp_old_q) / 32768.0f;
                    float exp_new_qf = static_cast<float>(exp_new_q) / 32768.0f;
                    exp_acc.add(static_cast<double>(exp_old_qf - exp_old_f));
                    exp_acc.add(static_cast<double>(exp_new_qf - exp_new_f));

                    float l_new_f = l_ref[qi] * exp_old_f + exp_new_f;
                    uint32_t l_scaled = (static_cast<uint64_t>(l_rtl[qi]) * exp_old_q) >> 15;
                    uint32_t l_term = (static_cast<uint32_t>(exp_new_q) << 1);
                    l_rtl[qi] = to_u32(static_cast<uint64_t>(l_scaled) + l_term);
                    float l_new_qf = static_cast<float>(l_rtl[qi]) / 65536.0f;
                    l_acc.add(static_cast<double>(l_new_qf - l_new_f));

                    for (int d = 0; d < cfg.D; ++d) {
                        float acc_new_f = acc_ref[qi][d] * exp_old_f + exp_new_f * vf[j][d];
                        int64_t acc_old_sc = (static_cast<int64_t>(acc_rtl[qi][d]) * exp_old_q) >> 15;
                        int64_t pv_term = (static_cast<int64_t>(exp_new_q) * static_cast<int32_t>(v_q[j][d])) >> 7;
                        acc_rtl[qi][d] = to_s32(acc_old_sc + pv_term);
                        float acc_new_qf = static_cast<float>(acc_rtl[qi][d]) / 256.0f;
                        acc_acc.add(static_cast<double>(acc_new_qf - acc_new_f));
                        acc_ref[qi][d] = acc_new_f;
                    }

                    l_ref[qi] = l_new_f;
                    m_ref[qi] = m_new_f;
                    m_rtl[qi] = m_new_q;
                }
            }
        }

        for (int qi = 0; qi < cfg.TQ; ++qi) {
            float l_ref_safe = std::max(l_ref[qi], 1e-20f);
            uint32_t recip = recip_q16_16(l_rtl[qi]);
            for (int d = 0; d < cfg.D; ++d) {
                float out_ref = acc_ref[qi][d] / l_ref_safe;
                int64_t norm_mul = static_cast<int64_t>(acc_rtl[qi][d]) * static_cast<int64_t>(static_cast<int32_t>(recip));
                int32_t norm_q = static_cast<int32_t>(norm_mul >> 16);
                float out_q = q8_8_to_float(sat_s16(norm_q));
                norm_acc.add(static_cast<double>(out_q - out_ref));
            }
        }
    }

    StageDecompResult r;
    r.dot = dot_acc.done();
    r.score = score_acc.done();
    r.exp = exp_acc.done();
    r.l = l_acc.done();
    r.acc = acc_acc.done();
    r.norm = norm_acc.done();

    if (!cfg.stage_csv_out.empty()) {
        std::ofstream csv(cfg.stage_csv_out);
        csv << "seed,stage,mae,maxe,rmse\n";
        auto wr = [&](const std::string& name, const StageMetrics& m) {
            csv << seed << "," << name << "," << m.mae << "," << m.maxe << "," << m.rmse << "\n";
        };
        wr("dot", r.dot);
        wr("score", r.score);
        wr("exp", r.exp);
        wr("l", r.l);
        wr("acc", r.acc);
        wr("norm", r.norm);
    }

    return r;
}

std::vector<ComputeCycleResult> run_compute_cycle_models(const Config& cfg) {
    std::vector<CycleModelCfg> models = {
        {"rtl_current_serial_l4", 4, 1, 3, false, 1, 1},
        {"merge_post_serial_l4", 4, 1, 2, false, 1, 1},
        {"dp_post_overlap_l4", 4, 1, 3, true, 1, 1},
        {"dp_post_overlap_l8", 8, 1, 3, true, 1, 1},
        {"dp_post_overlap_l16", 16, 1, 3, true, 1, 1},
        {"dp_post_overlap_l16_norm4", 16, 1, 3, true, 1, 4},
        {"dp_post_overlap_l16_norm4_row2", 16, 1, 3, true, 2, 4},
        {"fixed_flow_l32_norm8_row2", 32, 1, 3, true, 2, 8},
        {"fixed_flow_l32_norm8_row4", 32, 1, 3, true, 4, 8},
        {"simple_noc_l16_norm4_row4", 16, 1, 3, true, 4, 4, 1, 64},
        {"simple_noc_l32_norm8_row4", 32, 1, 3, true, 4, 8, 1, 64},
    };

    std::vector<ComputeCycleResult> out;
    out.reserve(models.size());
    for (const auto& m : models) {
        out.push_back(simulate_compute_cycles(cfg, m));
    }

    if (!cfg.cycle_csv_out.empty()) {
        std::ofstream csv(cfg.cycle_csv_out);
        csv << "model,S,D,TQ,TK,pair_total,compute_cycles,norm_cycles,noc_cycles,total_compute_only_cycles,pair_throughput_cycles,target_300k_pass\n";
        for (const auto& r : out) {
            csv << r.name << ","
                << cfg.S << "," << cfg.D << "," << cfg.TQ << "," << cfg.TK << ","
                << r.pair_total << ","
                << r.compute_cycles << ","
                << r.norm_cycles << ","
                << r.noc_cycles << ","
                << r.total_compute_only_cycles << ","
                << r.pair_throughput_cycles << ","
                << ((r.total_compute_only_cycles < 300000) ? 1 : 0)
                << "\n";
        }
    }

    return out;
}

Config parse_args(int argc, char** argv) {
    Config cfg;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&](int& idx) -> std::string {
            if (idx + 1 >= argc) throw std::runtime_error("Missing value for " + a);
            return argv[++idx];
        };

        if (a == "--s") cfg.S = std::stoi(next(i));
        else if (a == "--d") cfg.D = std::stoi(next(i));
        else if (a == "--tq") cfg.TQ = std::stoi(next(i));
        else if (a == "--tk") cfg.TK = std::stoi(next(i));
        else if (a == "--seed") cfg.seed = std::stoi(next(i));
        else if (a == "--n-seeds") cfg.n_seeds = std::stoi(next(i));
        else if (a == "--causal") cfg.causal = true;
        else if (a == "--non-causal") cfg.causal = false;
        else if (a == "--csv-out") cfg.csv_out = next(i);
        else if (a == "--input-mode") cfg.input_mode = next(i);
        else if (a == "--neg-large-q8_8") cfg.neg_large_q8_8 = std::stoi(next(i));
        else if (a == "--neg-large-fp32") cfg.neg_large_fp32 = std::stof(next(i));
        else if (a == "--bf16-low") cfg.bf16_low = std::stof(next(i));
        else if (a == "--bf16-high") cfg.bf16_high = std::stof(next(i));
        else if (a == "--mask-mode") cfg.mask_mode = next(i);
        else if (a == "--run-stage-decomp") cfg.run_stage_decomp = true;
        else if (a == "--stage-seed") cfg.stage_seed = std::stoi(next(i));
        else if (a == "--stage-csv-out") cfg.stage_csv_out = next(i);
        else if (a == "--run-compute-cycle-model") cfg.run_compute_cycle_model = true;
        else if (a == "--cycle-csv-out") cfg.cycle_csv_out = next(i);
        else if (a == "--run-module-eval") cfg.run_module_eval = true;
        else if (a == "--module-csv-out") cfg.module_csv_out = next(i);
        else throw std::runtime_error("Unknown arg: " + a);
    }
    if (cfg.mask_mode != "neg" && cfg.mask_mode != "hard") {
        throw std::runtime_error("--mask-mode must be neg|hard");
    }
    return cfg;
}

} // namespace attn
