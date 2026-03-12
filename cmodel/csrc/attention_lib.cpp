#include "attention_lib.hpp"

#include "attention_core.hpp"

#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#include <algorithm>
#include <utility>
#include <vector>

int run_cmodel(int argc, char** argv) {
    try {
        attn::Config cfg = attn::parse_args(argc, argv);
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
                  << " neg_large_fp32=" << cfg.neg_large_fp32
                  << " mask_mode=" << cfg.mask_mode
                  << " seeds=" << cfg.n_seeds << "\n";

        std::vector<std::string> names;

        struct Agg {
            double mae_sum = 0;
            double maxe_max = 0;
            double rmse_sum = 0;
            int cnt = 0;
            int worst_seed = 0;
            int worst_i = -1;
            int worst_d = -1;
        };
        std::vector<Agg> aggs;

        std::ofstream csv;
        if (!cfg.csv_out.empty()) {
            csv.open(cfg.csv_out);
            csv << "seed,mode,causal,input_mode,mask_mode,neg_large_q8_8,mae,maxe,rmse,max_i,max_d\n";
        }

        for (int k = 0; k < cfg.n_seeds; ++k) {
            int seed = cfg.seed + k;
            auto rs = attn::run_one_seed(cfg, seed);
            if (names.empty()) {
                for (const auto& r : rs) names.push_back(r.name);
                aggs.assign(names.size(), Agg{});
            }
            if (rs.size() != names.size()) {
                throw std::runtime_error("Mode count mismatch across seeds");
            }
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

        auto it_rtl = std::find(names.begin(), names.end(), "rtl_strict");
        if (it_rtl != names.end()) {
            size_t idx = static_cast<size_t>(std::distance(names.begin(), it_rtl));
            std::cout << "[cmodel] threshold check on rtl_strict: "
                      << "MAE<=0.03=" << ((aggs[idx].mae_sum / aggs[idx].cnt <= 0.03) ? "PASS" : "FAIL")
                      << ", MaxAE<=0.10=" << ((aggs[idx].maxe_max <= 0.10) ? "PASS" : "FAIL")
                      << "\n";
        }

        auto it_opt = std::find(names.begin(), names.end(), "fixed_hiacc_real_exp_qout");
        if (it_opt != names.end()) {
            size_t idx = static_cast<size_t>(std::distance(names.begin(), it_opt));
            std::cout << "[cmodel] threshold check on fixed_hiacc_real_exp_qout: "
                      << "MAE<=0.03=" << ((aggs[idx].mae_sum / aggs[idx].cnt <= 0.03) ? "PASS" : "FAIL")
                      << ", MaxAE<=0.10=" << ((aggs[idx].maxe_max <= 0.10) ? "PASS" : "FAIL")
                      << "\n";
        }

        if (cfg.run_stage_decomp || !cfg.stage_csv_out.empty()) {
            int stage_seed = (cfg.stage_seed >= 0) ? cfg.stage_seed : cfg.seed;
            auto st = attn::run_stage_decomposition(cfg, stage_seed);
            std::vector<std::pair<std::string, attn::StageMetrics>> stages = {
                {"dot", st.dot},
                {"score", st.score},
                {"exp", st.exp},
                {"l", st.l},
                {"acc", st.acc},
                {"norm", st.norm},
            };

            std::cout << "[stage-decomp] seed=" << stage_seed << "\n";
            for (const auto& kv : stages) {
                std::cout << "  " << kv.first
                          << " MAE=" << kv.second.mae
                          << " MaxAE=" << kv.second.maxe
                          << " RMSE=" << kv.second.rmse << "\n";
            }

            size_t best_idx = 0;
            for (size_t i = 1; i < stages.size(); ++i) {
                if (stages[i].second.mae > stages[best_idx].second.mae) best_idx = i;
            }
            std::cout << "[stage-decomp] dominant stage by MAE: " << stages[best_idx].first
                      << " (MAE=" << stages[best_idx].second.mae << ")\n";
            if (!cfg.stage_csv_out.empty()) {
                std::cout << "[stage-decomp] csv written: " << cfg.stage_csv_out << "\n";
            }
        }

        if (cfg.run_module_eval || !cfg.module_csv_out.empty()) {
            int module_seed = (cfg.stage_seed >= 0) ? cfg.stage_seed : cfg.seed;
            auto mod = attn::run_module_error_eval_bf16(cfg, module_seed);
            std::vector<std::pair<std::string, attn::StageMetrics>> mods = {
                {"fp32_add", mod.fp32_add},
                {"fp32_mul_q16", mod.fp32_mul_q16},
                {"fp32_exp2_pwl", mod.fp32_exp2_pwl},
                {"fp32_recip", mod.fp32_recip},
                {"fp32_to_bf16", mod.fp32_to_bf16},
            };

            std::cout << "[module-eval] seed=" << module_seed << "\n";
            for (const auto& kv : mods) {
                std::cout << "  " << kv.first
                          << " MAE=" << kv.second.mae
                          << " MaxAE=" << kv.second.maxe
                          << " RMSE=" << kv.second.rmse << "\n";
            }

            size_t best_idx = 0;
            for (size_t i = 1; i < mods.size(); ++i) {
                if (mods[i].second.mae > mods[best_idx].second.mae) best_idx = i;
            }
            std::cout << "[module-eval] dominant module by MAE: " << mods[best_idx].first
                      << " (MAE=" << mods[best_idx].second.mae << ")\n";

            if (!cfg.module_csv_out.empty()) {
                std::ofstream csv(cfg.module_csv_out);
                csv << "seed,module,mae,maxe,rmse\n";
                for (const auto& kv : mods) {
                    csv << module_seed << "," << kv.first << ","
                        << kv.second.mae << "," << kv.second.maxe << "," << kv.second.rmse << "\n";
                }
                std::cout << "[module-eval] csv written: " << cfg.module_csv_out << "\n";
            }
        }

        if (cfg.run_compute_cycle_model || !cfg.cycle_csv_out.empty()) {
            auto cycles = attn::run_compute_cycle_models(cfg);
            std::cout << "[compute-cycle-model] S=" << cfg.S << " D=" << cfg.D
                      << " (compute-only, no DMA, no multiplier/Fmax modeling)\n";
            for (const auto& c : cycles) {
                std::cout << "  " << c.name
                          << " pair_total=" << c.pair_total
                          << " compute=" << c.compute_cycles
                          << " norm=" << c.norm_cycles
                          << " noc=" << c.noc_cycles
                          << " total=" << c.total_compute_only_cycles
                          << " pair_cyc=" << std::fixed << std::setprecision(4) << c.pair_throughput_cycles
                          << " target<300k=" << ((c.total_compute_only_cycles < 300000) ? "PASS" : "FAIL")
                          << "\n";
            }
            if (!cfg.cycle_csv_out.empty()) {
                std::cout << "[compute-cycle-model] csv written: " << cfg.cycle_csv_out << "\n";
            }
        }

        return 0;
    } catch (const std::exception& e) {
        std::cerr << "[ERR] " << e.what() << "\n";
        return 1;
    }
}
