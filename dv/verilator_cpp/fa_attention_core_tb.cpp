#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <fstream>
#include <limits>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

#include "Vfa_attention_core.h"
#include "Vfa_attention_core___024root.h"
#include "verilated.h"

namespace {

constexpr int S = 256;
constexpr int D = 64;
constexpr int TQ = 32;
constexpr int TK = 64;
constexpr int BUS_W = 128;
constexpr int ELEMS_PER_BEAT = BUS_W / 16;   // 8
constexpr int BEATS_PER_ROW = D / ELEMS_PER_BEAT; // 8

constexpr uint64_t Q_BASE = 0x00000000ull;
constexpr uint64_t K_BASE = 0x00010000ull;
constexpr uint64_t V_BASE = 0x00020000ull;
constexpr uint64_t O_BASE = 0x00030000ull;

using MatrixI16 = std::vector<std::vector<int16_t>>;
using BeatWords = std::array<uint32_t, 4>; // 128-bit little-endian words

static inline int16_t sat_s16(int32_t v) {
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return static_cast<int16_t>(v);
}

static inline int32_t to_s32(int64_t v) {
    uint32_t u = static_cast<uint32_t>(v & 0xFFFFFFFFu);
    return static_cast<int32_t>(u);
}

static inline uint32_t to_u32(uint64_t v) {
    return static_cast<uint32_t>(v & 0xFFFFFFFFu);
}

static inline int16_t q8_8_mul_sat(int16_t a, int16_t b) {
    int32_t prod = static_cast<int32_t>(a) * static_cast<int32_t>(b);
    int32_t rounded = (prod >= 0) ? (prod + 128) : (prod - 128);
    int32_t shifted = rounded >> 8;
    return sat_s16(shifted);
}

static uint16_t exp_pwl_q1_15(int16_t x_q8_8) {
    int32_t x = x_q8_8;
    if (x > 0) x = 0;
    if (x < -4096) x = -4096;

    int32_t u_q8_8 = -x;
    int seg_idx;
    int frac;
    int u_int = (u_q8_8 >> 8) & 0xFF;
    if (u_int >= 8) {
        return 0;
    } else {
        seg_idx = (u_q8_8 >> 8) & 0x7;
        frac = u_q8_8 & 0xFF;
    }

    static const int table[8][2] = {
        {32767, 12055},
        {12055, 4431},
        {4431, 1631},
        {1631, 600},
        {600, 221},
        {221, 81},
        {81, 30},
        {30, 11},
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
    if (x < -16.0) x = -16.0;
    double y = std::exp(x);
    int v = static_cast<int>(std::llround(y * 32768.0));
    if (v < 0) v = 0;
    if (v > 65535) v = 65535;
    return static_cast<uint16_t>(v);
}

static uint16_t exp2_ctx_q1_15(int16_t x_q8_8) {
    int32_t x = x_q8_8;
    if (x > 0) x = 0;
    if (x < -4096) x = -4096;

    uint32_t z_q8_8 = ((static_cast<uint32_t>(-x) * 369u) + 128u) >> 8;
    uint32_t int_part = (z_q8_8 >> 8) & 0xFFu;
    uint32_t frac_part = z_q8_8 & 0xFFu;
    static const int table[32] = {
        32768, 32066, 31379, 30706, 30048, 29405, 28774, 28158,
        27554, 26964, 26386, 25821, 25268, 24726, 24196, 23678,
        23170, 22674, 22188, 21713, 21247, 20792, 20347, 19911,
        19484, 19066, 18658, 18258, 17867, 17484, 17109, 16743,
    };
    if (int_part >= 16u) return 0;
    return static_cast<uint16_t>(table[frac_part >> 3] >> int_part);
}

static uint32_t recip_q16_16(uint32_t x_q16_16) {
    if (x_q16_16 == 0) return 0xFFFFFFFFu;
    uint64_t num = (1ull << 32);
    uint64_t q = num / x_q16_16;
    if (q > 0xFFFFFFFFull) return 0xFFFFFFFFu;
    return static_cast<uint32_t>(q);
}

static double q8_8_to_float(int16_t x) {
    return static_cast<double>(x) / 256.0;
}

struct DmaMemory {
    std::unordered_map<uint32_t, BeatWords> mem;

    static BeatWords pack_elems(const int16_t elems[ELEMS_PER_BEAT]) {
        BeatWords w{0, 0, 0, 0};
        for (int i = 0; i < ELEMS_PER_BEAT; ++i) {
            uint16_t u = static_cast<uint16_t>(elems[i]);
            int word = i / 2;
            int shift = (i % 2) * 16;
            w[word] |= (static_cast<uint32_t>(u) << shift);
        }
        return w;
    }

    static void unpack_elems(const BeatWords& w, int16_t elems[ELEMS_PER_BEAT]) {
        for (int i = 0; i < ELEMS_PER_BEAT; ++i) {
            int word = i / 2;
            int shift = (i % 2) * 16;
            uint16_t u = static_cast<uint16_t>((w[word] >> shift) & 0xFFFFu);
            elems[i] = static_cast<int16_t>(u);
        }
    }

    void store_matrix_q8_8(uint32_t base_addr, const MatrixI16& mat, uint32_t stride_bytes) {
        int rows = static_cast<int>(mat.size());
        int cols = static_cast<int>(mat[0].size());
        for (int r = 0; r < rows; ++r) {
            uint32_t row_addr = base_addr + r * stride_bytes;
            for (int b = 0; b < cols / ELEMS_PER_BEAT; ++b) {
                int16_t elems[ELEMS_PER_BEAT];
                for (int e = 0; e < ELEMS_PER_BEAT; ++e) {
                    elems[e] = mat[r][b * ELEMS_PER_BEAT + e];
                }
                mem[row_addr + b * (BUS_W / 8)] = pack_elems(elems);
            }
        }
    }

    MatrixI16 load_matrix_q8_8(uint32_t base_addr, int rows, int cols, uint32_t stride_bytes) const {
        MatrixI16 out(rows, std::vector<int16_t>(cols, 0));
        for (int r = 0; r < rows; ++r) {
            uint32_t row_addr = base_addr + r * stride_bytes;
            for (int b = 0; b < cols / ELEMS_PER_BEAT; ++b) {
                uint32_t addr = row_addr + b * (BUS_W / 8);
                BeatWords w{0, 0, 0, 0};
                auto it = mem.find(addr);
                if (it != mem.end()) w = it->second;
                int16_t elems[ELEMS_PER_BEAT];
                unpack_elems(w, elems);
                for (int e = 0; e < ELEMS_PER_BEAT; ++e) {
                    out[r][b * ELEMS_PER_BEAT + e] = elems[e];
                }
            }
        }
        return out;
    }
};

static int16_t div_round_sat_s16(int64_t num, uint32_t den) {
    if (den == 0) return (num >= 0) ? 32767 : -32768;
    int64_t adj = static_cast<int64_t>(den) / 2;
    int64_t q = (num >= 0) ? ((num + adj) / static_cast<int64_t>(den))
                           : ((num - adj) / static_cast<int64_t>(den));
    return sat_s16(static_cast<int32_t>(q));
}

static MatrixI16 reference_fixed_like(const MatrixI16& Q, const MatrixI16& K, const MatrixI16& V, bool use_step_exp, bool causal) {
    MatrixI16 O(S, std::vector<int16_t>(D, 0));
    int16_t neg_large = static_cast<int16_t>(-8192); // -32.0 Q8.8
    int16_t scale = static_cast<int16_t>(std::lround((1.0 / std::sqrt(static_cast<double>(D))) * 256.0));

    for (int qt = 0; qt < S / TQ; ++qt) {
        int q_start = qt * TQ;
        std::vector<int16_t> row_m(TQ, neg_large);
        std::vector<uint32_t> row_l(TQ, 0);
        std::vector<std::vector<int64_t>> row_acc(TQ, std::vector<int64_t>(D, 0));

        for (int kt = 0; kt < S / TK; ++kt) {
            int k_start = kt * TK;
            for (int qi = 0; qi < TQ; ++qi) {
                for (int kj = 0; kj < TK; ++kj) {
                    int64_t dp = 0;
                    for (int d = 0; d < D; ++d) {
                        dp += static_cast<int32_t>(Q[q_start + qi][d]) * static_cast<int32_t>(K[k_start + kj][d]);
                    }
                    int16_t dp_q8_8 = static_cast<int16_t>((dp >> 8) & 0xFFFF);
                    int16_t score = q8_8_mul_sat(dp_q8_8, scale);
                    if (causal && (q_start + qi) < (k_start + kj)) {
                        score = neg_large;
                    }

                    int16_t m_old = row_m[qi];
                    int16_t m_new = (score > m_old) ? score : m_old;
                    int16_t diff_old = static_cast<int16_t>(m_old - m_new);
                    int16_t diff_new = static_cast<int16_t>(score - m_new);
                    uint16_t exp_old = use_step_exp ? exp2_ctx_q1_15(diff_old) : exp_real_q1_15(diff_old);
                    uint16_t exp_new = use_step_exp ? exp2_ctx_q1_15(diff_new) : exp_real_q1_15(diff_new);

                    uint32_t l_scaled = (static_cast<uint64_t>(row_l[qi]) * exp_old) >> 15;
                    uint32_t l_term = (static_cast<uint32_t>(exp_new) << 1);
                    row_l[qi] = to_u32(static_cast<uint64_t>(l_scaled) + l_term);

                    for (int d = 0; d < D; ++d) {
                        int64_t acc_old_sc = (row_acc[qi][d] * static_cast<int64_t>(exp_old)) >> 15;
                        int64_t pv_term = (static_cast<int64_t>(exp_new) * static_cast<int32_t>(V[k_start + kj][d])) >> 7;
                        row_acc[qi][d] = to_s32(acc_old_sc + pv_term);
                    }

                    row_m[qi] = m_new;
                }
            }
        }

        for (int qi = 0; qi < TQ; ++qi) {
            for (int d = 0; d < D; ++d) {
                int64_t num = row_acc[qi][d] << 8;
                uint32_t recip = recip_q16_16(row_l[qi]);
                __int128 norm_mul_q32_32 = static_cast<__int128>(num) * static_cast<int64_t>(static_cast<int32_t>(recip));
                __int128 norm_round_q32_32 = (norm_mul_q32_32 >= 0)
                    ? (norm_mul_q32_32 + static_cast<__int128>(2147483648ll))
                    : (norm_mul_q32_32 - static_cast<__int128>(2147483648ll));
                O[q_start + qi][d] = sat_s16(static_cast<int32_t>(norm_round_q32_32 >> 32));
            }
        }
    }

    return O;
}

static std::vector<std::vector<double>> reference_fp32(const MatrixI16& Q, const MatrixI16& K, const MatrixI16& V) {
    std::vector<std::vector<double>> O(S, std::vector<double>(D, 0.0));
    const double scale = 1.0 / std::sqrt(static_cast<double>(D));

    for (int i = 0; i < S; ++i) {
        std::vector<double> scores(S, 0.0);
        double max_s = -1e30;
        for (int j = 0; j < S; ++j) {
            double dot = 0.0;
            for (int d = 0; d < D; ++d) {
                dot += q8_8_to_float(Q[i][d]) * q8_8_to_float(K[j][d]);
            }
            scores[j] = dot * scale;
            if (j > i) scores[j] = -1e9;
            if (scores[j] > max_s) max_s = scores[j];
        }
        double denom = 0.0;
        for (int j = 0; j < S; ++j) {
            scores[j] = std::exp(scores[j] - max_s);
            denom += scores[j];
        }
        for (int j = 0; j < S; ++j) scores[j] /= denom;

        for (int d = 0; d < D; ++d) {
            double acc = 0.0;
            for (int j = 0; j < S; ++j) {
                acc += scores[j] * q8_8_to_float(V[j][d]);
            }
            O[i][d] = acc;
        }
    }
    return O;
}

struct Metrics {
    double mae = 0.0;
    double max_ae = 0.0;
    int max_i = -1;
    int max_d = -1;
};

static Metrics compare_i16_to_i16(const MatrixI16& a, const MatrixI16& b) {
    Metrics m;
    int64_t n = 0;
    for (int i = 0; i < S; ++i) {
        for (int d = 0; d < D; ++d) {
            double e = std::fabs(static_cast<double>(a[i][d] - b[i][d]));
            m.mae += e;
            if (e > m.max_ae) {
                m.max_ae = e;
                m.max_i = i;
                m.max_d = d;
            }
            ++n;
        }
    }
    m.mae /= static_cast<double>(n);
    return m;
}

static Metrics compare_i16_to_fp32(const MatrixI16& a, const std::vector<std::vector<double>>& b) {
    Metrics m;
    int64_t n = 0;
    for (int i = 0; i < S; ++i) {
        for (int d = 0; d < D; ++d) {
            double af = q8_8_to_float(a[i][d]);
            double e = std::fabs(af - b[i][d]);
            m.mae += e;
            if (e > m.max_ae) {
                m.max_ae = e;
                m.max_i = i;
                m.max_d = d;
            }
            ++n;
        }
    }
    m.mae /= static_cast<double>(n);
    return m;
}

struct ReadTxn {
    uint32_t addr = 0;
    uint32_t beats = 0;
    uint32_t idx = 0;
    bool active = false;
};

struct WriteTxn {
    uint32_t addr = 0;
    uint32_t beats = 0;
    uint32_t idx = 0;
    bool active = false;
};

struct TbConfig {
    std::string timeline_csv;
    std::string summary_csv;
};

struct ProfileEvent {
    uint64_t cycle;
    std::string event;
    std::string kind;
    uint32_t addr;
    uint32_t beats;
};

static TbConfig parse_args(int argc, char** argv) {
    TbConfig cfg;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&](int& idx) -> std::string {
            if (idx + 1 >= argc) {
                throw std::runtime_error("Missing value for " + a);
            }
            return argv[++idx];
        };

        if (a == "--timeline-csv") cfg.timeline_csv = next(i);
        else if (a == "--summary-csv") cfg.summary_csv = next(i);
        else throw std::runtime_error("Unknown arg: " + a);
    }
    return cfg;
}

static const char* rd_kind(uint32_t addr) {
    if (addr >= static_cast<uint32_t>(Q_BASE) && addr < static_cast<uint32_t>(Q_BASE + 0x10000)) return "Q";
    if (addr >= static_cast<uint32_t>(K_BASE) && addr < static_cast<uint32_t>(K_BASE + 0x10000)) return "K";
    if (addr >= static_cast<uint32_t>(V_BASE) && addr < static_cast<uint32_t>(V_BASE + 0x10000)) return "V";
    return "UNK";
}

int run_sim(const TbConfig& cfg) {
    Verilated::traceEverOn(false);
    auto* dut = new Vfa_attention_core();

    // Generate deterministic input
    std::mt19937 rng(2025);
    std::uniform_int_distribution<int> dist(-32, 31);
    MatrixI16 Q(S, std::vector<int16_t>(D));
    MatrixI16 K(S, std::vector<int16_t>(D));
    MatrixI16 V(S, std::vector<int16_t>(D));
    for (int i = 0; i < S; ++i) {
        for (int d = 0; d < D; ++d) {
            Q[i][d] = static_cast<int16_t>(dist(rng));
        }
    }
    for (int i = 0; i < S; ++i) {
        for (int d = 0; d < D; ++d) {
            K[i][d] = static_cast<int16_t>(dist(rng));
        }
    }
    for (int i = 0; i < S; ++i) {
        for (int d = 0; d < D; ++d) {
            V[i][d] = static_cast<int16_t>(dist(rng));
        }
    }

    DmaMemory mem;
    const uint32_t stride_bytes = D * 2;
    mem.store_matrix_q8_8(static_cast<uint32_t>(Q_BASE), Q, stride_bytes);
    mem.store_matrix_q8_8(static_cast<uint32_t>(K_BASE), K, stride_bytes);
    mem.store_matrix_q8_8(static_cast<uint32_t>(V_BASE), V, stride_bytes);

    // Reset inputs
    dut->clk = 0;
    dut->rst_n = 0;
    dut->i_start = 0;
    dut->i_soft_reset = 0;
    dut->i_causal_en = 1;
    dut->i_scale_q8_8 = static_cast<uint16_t>(std::lround((1.0 / std::sqrt(static_cast<double>(D))) * 256.0));
    dut->i_neg_large_q8_8 = static_cast<uint16_t>(static_cast<int16_t>(-8192));
    dut->i_q_base = Q_BASE;
    dut->i_k_base = K_BASE;
    dut->i_v_base = V_BASE;
    dut->i_o_base = O_BASE;
    dut->i_stride_bytes = stride_bytes;

    dut->dma_rd_cmd_ready = 1;
    dut->dma_rd_data_valid = 0;
    dut->dma_rd_data_last = 0;
    dut->dma_rd_data[0] = 0;
    dut->dma_rd_data[1] = 0;
    dut->dma_rd_data[2] = 0;
    dut->dma_rd_data[3] = 0;

    dut->dma_wr_cmd_ready = 1;
    dut->dma_wr_data_ready = 1;

    ReadTxn rd;
    WriteTxn wr;
    std::vector<ProfileEvent> events;
    uint64_t rd_q_cycles = 0;
    uint64_t rd_k_cycles = 0;
    uint64_t rd_v_cycles = 0;
    uint64_t wr_o_cycles = 0;
    uint64_t busy_cycles = 0;
    uint64_t perf_ms_load_q_cycles = 0;
    uint64_t perf_ms_init_context_cycles = 0;
    uint64_t perf_ms_load_k_cycles = 0;
    uint64_t perf_ms_load_v_cycles = 0;
    uint64_t perf_ms_compute_cycles = 0;
    uint64_t perf_ms_normalize_cycles = 0;
    uint64_t perf_ms_write_o_cycles = 0;
    uint64_t perf_ms_next_q_cycles = 0;
    uint64_t perf_cs_dp_cycles = 0;
    uint64_t perf_cs_score_cycles = 0;
    uint64_t perf_cs_softmax_cycles = 0;
    uint64_t perf_comp_launch_count = 0;
    uint64_t perf_norm_recip_req_count = 0;
    uint64_t perf_norm_recip_rsp_count = 0;

    bool profile_active = false;

    uint64_t cycles = 0;
    uint64_t max_cycles = 20000000ull;
    bool in_main_loop = false;

    auto eval_half = [&](int clk) {
        dut->clk = clk;
        dut->eval();
    };

    auto drive_before_posedge = [&]() {
        // Accept new read command
        if (!rd.active && dut->dma_rd_cmd_valid && dut->dma_rd_cmd_ready) {
            rd.addr = dut->dma_rd_cmd_addr;
            rd.beats = static_cast<uint32_t>(dut->dma_rd_cmd_len) + 1;
            rd.idx = 0;
            rd.active = true;
            events.push_back({cycles, "rd_cmd", rd_kind(rd.addr), rd.addr, rd.beats});
        }

        // Drive read data
        if (rd.active) {
            auto it = mem.mem.find(rd.addr + rd.idx * (BUS_W / 8));
            BeatWords w{0, 0, 0, 0};
            if (it != mem.mem.end()) w = it->second;
            dut->dma_rd_data_valid = 1;
            dut->dma_rd_data_last = (rd.idx + 1 == rd.beats) ? 1 : 0;
            dut->dma_rd_data[0] = w[0];
            dut->dma_rd_data[1] = w[1];
            dut->dma_rd_data[2] = w[2];
            dut->dma_rd_data[3] = w[3];
        } else {
            dut->dma_rd_data_valid = 0;
            dut->dma_rd_data_last = 0;
            dut->dma_rd_data[0] = 0;
            dut->dma_rd_data[1] = 0;
            dut->dma_rd_data[2] = 0;
            dut->dma_rd_data[3] = 0;
        }

        // Accept new write command
        if (!wr.active && dut->dma_wr_cmd_valid && dut->dma_wr_cmd_ready) {
            wr.addr = dut->dma_wr_cmd_addr;
            wr.beats = static_cast<uint32_t>(dut->dma_wr_cmd_len) + 1;
            wr.idx = 0;
            wr.active = true;
            events.push_back({cycles, "wr_cmd", "O", wr.addr, wr.beats});
        }
    };

    auto update_after_posedge = [&]() {
        // Read beat accepted
        if (rd.active && dut->dma_rd_data_valid && dut->dma_rd_data_ready) {
            const char* k = rd_kind(rd.addr);
            if (std::string(k) == "Q") rd_q_cycles++;
            else if (std::string(k) == "K") rd_k_cycles++;
            else if (std::string(k) == "V") rd_v_cycles++;
            rd.idx++;
            if (rd.idx >= rd.beats) {
                events.push_back({cycles, "rd_done", rd_kind(rd.addr), rd.addr, rd.beats});
                rd.active = false;
            }
        }

        // Write beat accepted
        if (wr.active && dut->dma_wr_data_valid && dut->dma_wr_data_ready) {
            wr_o_cycles++;
            BeatWords w{
                static_cast<uint32_t>(dut->dma_wr_data[0]),
                static_cast<uint32_t>(dut->dma_wr_data[1]),
                static_cast<uint32_t>(dut->dma_wr_data[2]),
                static_cast<uint32_t>(dut->dma_wr_data[3])
            };
            uint32_t addr = wr.addr + wr.idx * (BUS_W / 8);
            mem.mem[addr] = w;
            wr.idx++;
            if (wr.idx >= wr.beats) {
                events.push_back({cycles, "wr_done", "O", wr.addr, wr.beats});
                wr.active = false;
            }
        }

        if (dut->o_busy) profile_active = true;
        if (profile_active && in_main_loop) {
            if (dut->o_busy) busy_cycles++;
            if (dut->o_perf_ms_load_q) perf_ms_load_q_cycles++;
            if (dut->o_perf_ms_init_context) perf_ms_init_context_cycles++;
            if (dut->o_perf_ms_load_k) perf_ms_load_k_cycles++;
            if (dut->o_perf_ms_load_v) perf_ms_load_v_cycles++;
            if (dut->o_perf_ms_compute) perf_ms_compute_cycles++;
            if (dut->o_perf_ms_normalize) perf_ms_normalize_cycles++;
            if (dut->o_perf_ms_write_o) perf_ms_write_o_cycles++;
            if (dut->o_perf_ms_next_q) perf_ms_next_q_cycles++;
            if (dut->o_perf_cs_dp_run) perf_cs_dp_cycles++;
            if (dut->o_perf_cs_score_done) perf_cs_score_cycles++;
            if (dut->o_perf_cs_softmax_prep) perf_cs_softmax_cycles++;
            if (dut->o_perf_comp_launch) perf_comp_launch_count++;
            if (dut->o_perf_norm_recip_req) perf_norm_recip_req_count++;
            if (dut->o_perf_norm_recip_rsp) perf_norm_recip_rsp_count++;
        }
    };

    // Reset sequence
    for (int i = 0; i < 4; ++i) {
        eval_half(0);
        drive_before_posedge();
        eval_half(1);
        update_after_posedge();
    }
    dut->rst_n = 1;

    // Start pulse
    eval_half(0);
    dut->i_start = 1;
    drive_before_posedge();
    eval_half(1);
    update_after_posedge();

    eval_half(0);
    dut->i_start = 0;
    drive_before_posedge();
    eval_half(1);
    update_after_posedge();

    bool done = false;
    in_main_loop = true;
    while (cycles < max_cycles) {
        eval_half(0);
        drive_before_posedge();
        eval_half(1);
        update_after_posedge();

        cycles++;
        if (dut->o_done) {
            done = true;
            break;
        }
    }
    in_main_loop = false;

    if (!done) {
        std::cerr << "[TB] Timeout after cycles=" << cycles << "\n";
        delete dut;
        return 2;
    }

    events.push_back({cycles, "done", "CORE", 0, 0});

    MatrixI16 O_rtl = mem.load_matrix_q8_8(static_cast<uint32_t>(O_BASE), S, D, stride_bytes);

    // Round-2 diagnostics: fixed-like + FP32 references
    MatrixI16 O_fixed = reference_fixed_like(Q, K, V, true, true);
    MatrixI16 O_fixed_realexp = reference_fixed_like(Q, K, V, false, true);
    auto O_fp32 = reference_fp32(Q, K, V);

    Metrics m_rtl_fixed = compare_i16_to_i16(O_rtl, O_fixed);
    Metrics m_rtl_fixed_realexp = compare_i16_to_i16(O_rtl, O_fixed_realexp);
    Metrics m_fixed_fp32 = compare_i16_to_fp32(O_fixed, O_fp32);
    Metrics m_fixed_realexp_fp32 = compare_i16_to_fp32(O_fixed_realexp, O_fp32);
    Metrics m_rtl_fp32 = compare_i16_to_fp32(O_rtl, O_fp32);

    std::cout << std::fixed << std::setprecision(6);
    std::cout << "[Verilator C++ TB] DONE cycles=" << cycles << " o_cycles=" << dut->o_cycles << "\n";
    std::cout << "[Verilator C++ TB] PERF summary: busy=" << busy_cycles
              << " load_q=" << perf_ms_load_q_cycles
              << " init=" << perf_ms_init_context_cycles
              << " load_k=" << perf_ms_load_k_cycles
              << " load_v=" << perf_ms_load_v_cycles
              << " compute=" << perf_ms_compute_cycles
              << " norm=" << perf_ms_normalize_cycles
              << " write_o=" << perf_ms_write_o_cycles
              << " next_q=" << perf_ms_next_q_cycles << "\n";
    std::cout << "[Verilator C++ TB] PERF compute split: dp=" << perf_cs_dp_cycles
              << " score=" << perf_cs_score_cycles
              << " softmax=" << perf_cs_softmax_cycles
              << " comp_launch=" << perf_comp_launch_count
              << " recip_req=" << perf_norm_recip_req_count
              << " recip_rsp=" << perf_norm_recip_rsp_count << "\n";
    std::cout << "[Verilator C++ TB] RTL vs FixedLike: MAE=" << m_rtl_fixed.mae
              << " MAX_AE=" << m_rtl_fixed.max_ae
              << " @(" << m_rtl_fixed.max_i << "," << m_rtl_fixed.max_d << ")\n";
    std::cout << "[Verilator C++ TB] RTL vs FixedLike(real-exp): MAE=" << m_rtl_fixed_realexp.mae
              << " MAX_AE=" << m_rtl_fixed_realexp.max_ae
              << " @(" << m_rtl_fixed_realexp.max_i << "," << m_rtl_fixed_realexp.max_d << ")\n";
    std::cout << "[Verilator C++ TB] FixedLike vs FP32: MAE=" << m_fixed_fp32.mae
              << " MAX_AE=" << m_fixed_fp32.max_ae
              << " @(" << m_fixed_fp32.max_i << "," << m_fixed_fp32.max_d << ")\n";
    std::cout << "[Verilator C++ TB] FixedLike(real-exp) vs FP32: MAE=" << m_fixed_realexp_fp32.mae
              << " MAX_AE=" << m_fixed_realexp_fp32.max_ae
              << " @(" << m_fixed_realexp_fp32.max_i << "," << m_fixed_realexp_fp32.max_d << ")\n";
    std::cout << "[Verilator C++ TB] RTL vs FP32: MAE=" << m_rtl_fp32.mae
              << " MAX_AE=" << m_rtl_fp32.max_ae
              << " @(" << m_rtl_fp32.max_i << "," << m_rtl_fp32.max_d << ")\n";

    bool pass_fp32 = (m_rtl_fp32.mae <= 0.03) && (m_rtl_fp32.max_ae <= 0.10);
    std::cout << "[Verilator C++ TB] FP32 thresholds: MAE<=0.03 "
              << ((m_rtl_fp32.mae <= 0.03) ? "PASS" : "FAIL")
              << ", MAX_AE<=0.10 "
              << ((m_rtl_fp32.max_ae <= 0.10) ? "PASS" : "FAIL") << "\n";

    if (!cfg.timeline_csv.empty()) {
        std::ofstream tf(cfg.timeline_csv);
        tf << "cycle,event,kind,addr,beats\n";
        for (const auto& e : events) {
            tf << e.cycle << "," << e.event << "," << e.kind << "," << e.addr << "," << e.beats << "\n";
        }
    }
    if (!cfg.summary_csv.empty()) {
        uint64_t dma_cycles = rd_q_cycles + rd_k_cycles + rd_v_cycles + wr_o_cycles;
        uint64_t non_dma_cycles = (cycles > dma_cycles) ? (cycles - dma_cycles) : 0;
        uint64_t prof_total = perf_ms_load_q_cycles + perf_ms_init_context_cycles
                            + perf_ms_load_k_cycles + perf_ms_load_v_cycles
                            + perf_ms_compute_cycles + perf_ms_normalize_cycles
                            + perf_ms_write_o_cycles + perf_ms_next_q_cycles;
        uint64_t prof_unaccounted = (cycles > prof_total) ? (cycles - prof_total) : 0;
        std::ofstream sf(cfg.summary_csv);
        sf << "metric,value\n";
        sf << "total_cycles," << cycles << "\n";
        sf << "o_cycles," << static_cast<uint64_t>(dut->o_cycles) << "\n";
        sf << "busy_cycles," << busy_cycles << "\n";
        sf << "rd_q_cycles," << rd_q_cycles << "\n";
        sf << "rd_k_cycles," << rd_k_cycles << "\n";
        sf << "rd_v_cycles," << rd_v_cycles << "\n";
        sf << "wr_o_cycles," << wr_o_cycles << "\n";
        sf << "non_dma_cycles," << non_dma_cycles << "\n";
        sf << "perf_ms_load_q_cycles," << perf_ms_load_q_cycles << "\n";
        sf << "perf_ms_init_context_cycles," << perf_ms_init_context_cycles << "\n";
        sf << "perf_ms_load_k_cycles," << perf_ms_load_k_cycles << "\n";
        sf << "perf_ms_load_v_cycles," << perf_ms_load_v_cycles << "\n";
        sf << "perf_ms_compute_cycles," << perf_ms_compute_cycles << "\n";
        sf << "perf_ms_normalize_cycles," << perf_ms_normalize_cycles << "\n";
        sf << "perf_ms_write_o_cycles," << perf_ms_write_o_cycles << "\n";
        sf << "perf_ms_next_q_cycles," << perf_ms_next_q_cycles << "\n";
        sf << "perf_cs_dp_cycles," << perf_cs_dp_cycles << "\n";
        sf << "perf_cs_score_cycles," << perf_cs_score_cycles << "\n";
        sf << "perf_cs_softmax_cycles," << perf_cs_softmax_cycles << "\n";
        sf << "perf_comp_launch_count," << perf_comp_launch_count << "\n";
        sf << "perf_norm_recip_req_count," << perf_norm_recip_req_count << "\n";
        sf << "perf_norm_recip_rsp_count," << perf_norm_recip_rsp_count << "\n";
        sf << "profiled_total_cycles," << prof_total << "\n";
        sf << "profile_unaccounted_cycles," << prof_unaccounted << "\n";
        sf << "rtl_fp32_mae," << m_rtl_fp32.mae << "\n";
        sf << "rtl_fp32_maxae," << m_rtl_fp32.max_ae << "\n";
    }

    delete dut;
    return pass_fp32 ? 0 : 1;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        TbConfig cfg = parse_args(argc, argv);
        return run_sim(cfg);
    } catch (const std::exception& e) {
        std::cerr << "[TB][ERR] " << e.what() << "\n";
        return 2;
    }
}
