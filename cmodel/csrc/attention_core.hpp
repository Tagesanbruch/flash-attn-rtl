#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace attn {

struct Config {
    int S = 256;
    int D = 64;
    int TQ = 32;
    int TK = 64;
    int seed = 20260303;
    int n_seeds = 5;
    bool causal = true;
    std::string csv_out = "";
    std::string input_mode = "bf16";
    int neg_large_q8_8 = -2048;
    float neg_large_fp32 = -64.0f;
    float bf16_low = -1.0f;
    float bf16_high = 1.0f;
    std::string mask_mode = "neg";
    bool run_stage_decomp = false;
    int stage_seed = -1;
    std::string stage_csv_out = "";
    bool run_compute_cycle_model = false;
    std::string cycle_csv_out = "";
    bool run_module_eval = false;
    std::string module_csv_out = "";
};

using MatrixI16 = std::vector<std::vector<int16_t>>;
using MatrixU16 = std::vector<std::vector<uint16_t>>;
using MatrixF = std::vector<std::vector<float>>;

enum class Mode {
    RTL_STRICT,
    RTL_CTX_STEP,
    RTL_CTX_STEP_ACC24,
    RTL_CTX_INTERP,
    RTL_CTX_PWL,
    RTL_CTX_REAL_EXP,
    RTL_EXACT,
    RTL_REAL_EXP,
    RTL_REAL_EXP_FLOAT_NORM,
    FLOAT_ONLINE_Q8,
    ACC_FLOAT_QOUT,
    ACC_FLOAT_REAL_EXP_QOUT,
    FIXED_HIACC_QOUT,
    FIXED_HIACC_REAL_EXP_QOUT
};

struct Metrics {
    double mae = 0.0;
    double maxe = 0.0;
    double rmse = 0.0;
    int max_i = -1;
    int max_d = -1;
};

struct ModeResult {
    std::string name;
    Metrics m;
};

struct StageMetrics {
    double mae = 0.0;
    double maxe = 0.0;
    double rmse = 0.0;
};

struct StageDecompResult {
    StageMetrics dot;
    StageMetrics score;
    StageMetrics exp;
    StageMetrics l;
    StageMetrics acc;
    StageMetrics norm;
};

struct ModuleEvalResult {
    StageMetrics fp32_add;
    StageMetrics fp32_mul_q16;
    StageMetrics fp32_exp2_pwl;
    StageMetrics fp32_recip;
    StageMetrics fp32_to_bf16;
};

struct ComputeCycleResult {
    std::string name;
    int64_t pair_total = 0;
    int64_t compute_cycles = 0;
    int64_t norm_cycles = 0;
    int64_t noc_cycles = 0;
    int64_t total_compute_only_cycles = 0;
    double pair_throughput_cycles = 0.0;
};

int16_t sat_s16(int32_t v);
int32_t to_s32(int64_t v);
uint32_t to_u32(uint64_t v);
int16_t q8_8_mul_sat(int16_t a, int16_t b);
uint16_t exp_pwl_q1_15(int16_t x_q8_8);
uint16_t exp_real_q1_15(int16_t x_q8_8);
uint16_t exp2_ctx_step_q1_15(int16_t x_q8_8);
uint16_t exp2_ctx_interp_q1_15(int16_t x_q8_8);
uint32_t recip_q16_16(uint32_t x_q16_16);
uint32_t recip_nr_rtl_q16_16(uint32_t x_q16_16);
float q8_8_to_float(int16_t x);
int16_t float_to_q8_8(float x);
MatrixF dequant_q8_8(const MatrixI16& x);
MatrixI16 quant_q8_8(const MatrixF& x);

uint32_t f32_to_bits(float v);
float bits_to_f32(uint32_t bits);
uint16_t fp32_to_bf16_bits(uint32_t x_bits);
uint32_t bf16_to_fp32_bits(uint16_t bf16);
uint32_t fp32_add_ref_bits(uint32_t a_bits, uint32_t b_bits);
uint32_t fp32_add_rtl_bits(uint32_t a_bits, uint32_t b_bits);
uint32_t fp32_mul_q16_bits(uint32_t a_bits, uint32_t b_bits);
uint32_t fp32_exp2_pwl_bits(uint32_t x_bits);
uint32_t fp32_recip_bits(uint32_t x_bits);
uint32_t fp32_max_bits(uint32_t a_bits, uint32_t b_bits);
uint32_t fp32_neg_bits(uint32_t x_bits);

MatrixU16 attention_bf16_fp32_reference(const MatrixU16& q_bf16,
                                        const MatrixU16& k_bf16,
                                        const MatrixU16& v_bf16,
                                        int TQ, int TK,
                                        bool causal,
                                        uint32_t scale_bits,
                                        uint32_t neg_large_bits);

MatrixU16 online_rtl_like_bf16_fp32(const MatrixU16& q_bf16,
                                    const MatrixU16& k_bf16,
                                    const MatrixU16& v_bf16,
                                    int TQ, int TK,
                                    bool causal,
                                    uint32_t scale_bits,
                                    uint32_t neg_large_bits);

MatrixF direct_sdpa_fp32(const MatrixF& q, const MatrixF& k, const MatrixF& v, bool causal);
MatrixI16 online_rtl_like(const MatrixI16& Q, const MatrixI16& K, const MatrixI16& V,
                          int TQ, int TK, bool causal, Mode mode,
                          int16_t neg_large, bool hard_mask);

Metrics calc_metrics(const MatrixF& a, const MatrixF& b);
std::vector<ModeResult> run_one_seed(const Config& cfg, int seed);
StageDecompResult run_stage_decomposition(const Config& cfg, int seed);
ModuleEvalResult run_module_error_eval_bf16(const Config& cfg, int seed);
std::vector<ComputeCycleResult> run_compute_cycle_models(const Config& cfg);
Config parse_args(int argc, char** argv);

} // namespace attn
