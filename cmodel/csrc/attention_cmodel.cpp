#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <random>
#include <sstream>
#include <string>
#include <tuple>
#include <vector>

namespace {

struct Config {
    int S = 256;
    int D = 64;
    int TQ = 32;
    int TK = 64;
    int seed = 20260303;
    int n_seeds = 5;
    bool causal = true;
    std::string csv_out = "";
    std::string input_mode = "small-int";
    int neg_large_q8_8 = -2048; // default -8.0 in Q8.8
    std::string mask_mode = "neg"; // neg | hard
};

using MatrixI16 = std::vector<std::vector<int16_t>>;
using MatrixF = std::vector<std::vector<float>>;

static int16_t sat_s16(int32_t v) {
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return static_cast<int16_t>(v);
}

static int32_t to_s32(int64_t v) {
    uint32_t u = static_cast<uint32_t>(v & 0xFFFFFFFFu);
    return static_cast<int32_t>(u);
}

static uint32_t to_u32(uint64_t v) {
    return static_cast<uint32_t>(v & 0xFFFFFFFFu);
}

static int16_t q8_8_mul_sat(int16_t a, int16_t b) {
    int32_t prod = static_cast<int32_t>(a) * static_cast<int32_t>(b);
    int32_t rounded = (prod >= 0) ? (prod + 128) : (prod - 128);
    int32_t shifted = rounded >> 8;
    return sat_s16(shifted);
}

static uint16_t exp_pwl_q1_15(int16_t x_q8_8) {
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

static uint16_t exp_real_q1_15(int16_t x_q8_8) {
    double x = static_cast<double>(x_q8_8) / 256.0;
    if (x > 0.0) x = 0.0;
    if (x < -8.0) x = -8.0;
    int v = static_cast<int>(std::llround(std::exp(x) * 32768.0));
    v = std::max(0, std::min(65535, v));
    return static_cast<uint16_t>(v);
}

static uint32_t recip_q16_16(uint32_t x_q16_16) {
    if (x_q16_16 == 0) return 0xFFFFFFFFu;
    uint64_t num = (1ull << 32);
    uint64_t q = num / x_q16_16;
    if (q > 0xFFFFFFFFull) return 0xFFFFFFFFu;
    return static_cast<uint32_t>(q);
}

static float q8_8_to_float(int16_t x) {
    return static_cast<float>(x) / 256.0f;
}

static int16_t float_to_q8_8(float x) {
    int v = static_cast<int>(std::lround(static_cast<double>(x) * 256.0));
    return sat_s16(v);
}

static MatrixF dequant_q8_8(const MatrixI16& x) {
    MatrixF out(x.size(), std::vector<float>(x[0].size(), 0.0f));
    for (size_t i = 0; i < x.size(); ++i) {
        for (size_t j = 0; j < x[0].size(); ++j) {
            out[i][j] = q8_8_to_float(x[i][j]);
        }
    }
    return out;
}

static MatrixI16 quant_q8_8(const MatrixF& x) {
    MatrixI16 out(x.size(), std::vector<int16_t>(x[0].size(), 0));
    for (size_t i = 0; i < x.size(); ++i) {
        for (size_t j = 0; j < x[0].size(); ++j) {
            out[i][j] = float_to_q8_8(x[i][j]);
        }
    }
    return out;
}

static MatrixF direct_sdpa_fp32(const MatrixF& q, const MatrixF& k, const MatrixF& v, bool causal) {
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

enum class Mode {
    RTL_EXACT,
    RTL_REAL_EXP,
    RTL_REAL_EXP_FLOAT_NORM,
    FLOAT_ONLINE_Q8
};

static MatrixI16 online_rtl_like(const MatrixI16& Q, const MatrixI16& K, const MatrixI16& V,
                                 int TQ, int TK, bool causal, Mode mode,
                                 int16_t neg_large, bool hard_mask) {
    const int S = static_cast<int>(Q.size());
    const int D = static_cast<int>(Q[0].size());
    MatrixI16 O(S, std::vector<int16_t>(D, 0));
    const int16_t scale_q8_8 = static_cast<int16_t>(std::lround((1.0 / std::sqrt(static_cast<double>(D))) * 256.0));

    for (int qt = 0; qt < S / TQ; ++qt) {
        int q_start = qt * TQ;
        std::vector<int16_t> row_m(TQ, neg_large);
        std::vector<uint32_t> row_l(TQ, 0);
        std::vector<std::vector<int32_t>> row_acc(TQ, std::vector<int32_t>(D, 0));

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

                    uint16_t exp_old = (mode == Mode::RTL_EXACT || mode == Mode::FLOAT_ONLINE_Q8)
                        ? exp_pwl_q1_15(diff_old)
                        : exp_real_q1_15(diff_old);
                    uint16_t exp_new = (mode == Mode::RTL_EXACT || mode == Mode::FLOAT_ONLINE_Q8)
                        ? exp_pwl_q1_15(diff_new)
                        : exp_real_q1_15(diff_new);

                    uint32_t l_scaled = (static_cast<uint64_t>(row_l[qi]) * exp_old) >> 15;
                    uint32_t l_term = (static_cast<uint32_t>(exp_new) << 1);
                    row_l[qi] = to_u32(static_cast<uint64_t>(l_scaled) + l_term);

                    for (int d = 0; d < D; ++d) {
                        int64_t acc_old_sc = (static_cast<int64_t>(row_acc[qi][d]) * exp_old) >> 15;
                        int64_t pv_term = (static_cast<int64_t>(exp_new) * static_cast<int32_t>(V[global_j][d])) >> 7;
                        row_acc[qi][d] = to_s32(acc_old_sc + pv_term);
                    }

                    row_m[qi] = m_new;
                }
            }
        }

        for (int qi = 0; qi < TQ; ++qi) {
            if (mode == Mode::RTL_REAL_EXP_FLOAT_NORM || mode == Mode::FLOAT_ONLINE_Q8) {
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

struct Metrics {
    double mae = 0.0;
    double maxe = 0.0;
    double rmse = 0.0;
    int max_i = -1;
    int max_d = -1;
};

static Metrics calc_metrics(const MatrixF& a, const MatrixF& b) {
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

struct ModeResult {
    std::string name;
    Metrics m;
};

static std::vector<ModeResult> run_one_seed(const Config& cfg, int seed) {
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
        throw std::runtime_error("Unknown --input-mode, use small-int|gaussian");
    }

    MatrixF q_qf = dequant_q8_8(q_q);
    MatrixF k_qf = dequant_q8_8(k_q);
    MatrixF v_qf = dequant_q8_8(v_q);

    MatrixF fp32_ref = direct_sdpa_fp32(q_qf, k_qf, v_qf, cfg.causal);

    bool hard_mask = (cfg.mask_mode == "hard");
    int16_t neg_large = static_cast<int16_t>(cfg.neg_large_q8_8);

    MatrixF rtl_exact_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::RTL_EXACT, neg_large, hard_mask));
    MatrixF rtl_realexp_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::RTL_REAL_EXP, neg_large, hard_mask));
    MatrixF rtl_realexp_floatnorm_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::RTL_REAL_EXP_FLOAT_NORM, neg_large, hard_mask));
    MatrixF float_online_q8_f = dequant_q8_8(online_rtl_like(q_q, k_q, v_q, cfg.TQ, cfg.TK, cfg.causal, Mode::FLOAT_ONLINE_Q8, neg_large, hard_mask));

    std::vector<ModeResult> out;
    out.push_back({"rtl_exact", calc_metrics(rtl_exact_f, fp32_ref)});
    out.push_back({"rtl_real_exp", calc_metrics(rtl_realexp_f, fp32_ref)});
    out.push_back({"rtl_real_exp_float_norm", calc_metrics(rtl_realexp_floatnorm_f, fp32_ref)});
    out.push_back({"float_online_q8", calc_metrics(float_online_q8_f, fp32_ref)});
    return out;
}

static Config parse_args(int argc, char** argv) {
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
        else if (a == "--mask-mode") cfg.mask_mode = next(i);
        else throw std::runtime_error("Unknown arg: " + a);
    }
    if (cfg.mask_mode != "neg" && cfg.mask_mode != "hard") {
        throw std::runtime_error("--mask-mode must be neg|hard");
    }
    return cfg;
}

} // namespace

int main(int argc, char** argv) {
    try {
        Config cfg = parse_args(argc, argv);
        if (cfg.S % cfg.TQ != 0 || cfg.S % cfg.TK != 0) {
            std::cerr << "[ERR] S must be divisible by TQ and TK\n";
            return 2;
        }

        std::cout << "[cmodel] S=" << cfg.S
                  << " D=" << cfg.D
                  << " TQ=" << cfg.TQ
                  << " TK=" << cfg.TK
                  << " causal=" << (cfg.causal ? 1 : 0)
                  << " input_mode=" << cfg.input_mode
                  << " neg_large_q8_8=" << cfg.neg_large_q8_8
                  << " mask_mode=" << cfg.mask_mode
                  << " seeds=" << cfg.n_seeds << "\n";

        std::vector<std::string> names = {
            "rtl_exact", "rtl_real_exp", "rtl_real_exp_float_norm", "float_online_q8"
        };

        struct Agg { double mae_sum=0, maxe_max=0, rmse_sum=0; int cnt=0; int worst_seed=0; int worst_i=-1; int worst_d=-1;};
        std::vector<Agg> aggs(names.size());

        std::ofstream csv;
        if (!cfg.csv_out.empty()) {
            csv.open(cfg.csv_out);
            csv << "seed,mode,causal,input_mode,mask_mode,neg_large_q8_8,mae,maxe,rmse,max_i,max_d\n";
        }

        for (int k = 0; k < cfg.n_seeds; ++k) {
            int seed = cfg.seed + k;
            auto rs = run_one_seed(cfg, seed);
            std::cout << "seed=" << seed << "\n";
            for (size_t i = 0; i < rs.size(); ++i) {
                const auto& r = rs[i];
                std::cout << "  " << r.name
                          << " MAE=" << std::fixed << std::setprecision(6) << r.m.mae
                          << " MaxAE=" << r.m.maxe
                          << " RMSE=" << r.m.rmse
                          << " @(" << r.m.max_i << "," << r.m.max_d << ")\n";

                aggs[i].mae_sum += r.m.mae;
                aggs[i].rmse_sum += r.m.rmse;
                aggs[i].cnt += 1;
                if (r.m.maxe > aggs[i].maxe_max) {
                    aggs[i].maxe_max = r.m.maxe;
                    aggs[i].worst_seed = seed;
                    aggs[i].worst_i = r.m.max_i;
                    aggs[i].worst_d = r.m.max_d;
                }

                if (csv.is_open()) {
                    csv << seed << "," << r.name << ","
                        << (cfg.causal ? 1 : 0) << ","
                        << cfg.input_mode << ","
                        << cfg.mask_mode << ","
                        << cfg.neg_large_q8_8 << ","
                        << r.m.mae << "," << r.m.maxe << "," << r.m.rmse << ","
                        << r.m.max_i << "," << r.m.max_d << "\n";
                }
            }
        }

        std::cout << "------------------------------------------------------------\n";
        for (size_t i = 0; i < names.size(); ++i) {
            std::cout << names[i]
                      << " MAE(mean)=" << (aggs[i].mae_sum / aggs[i].cnt)
                      << " MaxAE(worst)=" << aggs[i].maxe_max
                      << " RMSE(mean)=" << (aggs[i].rmse_sum / aggs[i].cnt)
                      << " worst@seed=" << aggs[i].worst_seed
                      << " (" << aggs[i].worst_i << "," << aggs[i].worst_d << ")\n";
        }

        if (csv.is_open()) {
            std::cout << "[cmodel] csv written: " << cfg.csv_out << "\n";
        }

        std::cout << "[cmodel] threshold check on rtl_exact: "
                  << "MAE<=0.03=" << ((aggs[0].mae_sum / aggs[0].cnt <= 0.03) ? "PASS" : "FAIL")
                  << ", MaxAE<=0.10=" << ((aggs[0].maxe_max <= 0.10) ? "PASS" : "FAIL")
                  << "\n";

        return 0;
    } catch (const std::exception& e) {
        std::cerr << "[ERR] " << e.what() << "\n";
        return 1;
    }
}
