#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <random>
#include <vector>

#include "fa_cmodel_bridge.h"
#include "fa_dpi_backend.h"

static int run_one_case(int seq_len,
                        int head_size,
                        int neg_large_q8_8,
                        int cmodel_mode,
                        std::mt19937 &rng,
                        int &max_abs_out,
                        int &sum_abs_out,
                        int &count_diff_out) {
  const int kv_steps = seq_len + 1;
  const int kv_dim = head_size;
  const uint64_t q_base = 0x00000000ull;
  const uint64_t k_base = 0x00001000ull;
  const uint64_t v_base = 0x00002000ull;
  const uint64_t o_base = 0x00003000ull;
  const uint32_t stride_bytes = static_cast<uint32_t>(head_size * sizeof(int16_t));

  std::uniform_int_distribution<int> dist(-192, 192);

  std::vector<int16_t> q(head_size);
  std::vector<int16_t> k(kv_steps * kv_dim);
  std::vector<int16_t> v(kv_steps * kv_dim);
  std::vector<int16_t> o_rtl(head_size, 0);
  std::vector<int16_t> o_cmodel(head_size, 0);

  for (int i = 0; i < head_size; ++i) {
    q[i] = static_cast<int16_t>(dist(rng));
  }
  for (int i = 0; i < kv_steps * kv_dim; ++i) {
    k[i] = static_cast<int16_t>(dist(rng));
    v[i] = static_cast<int16_t>(dist(rng));
  }

  if (fa_dpi_mem_write(q_base, q.data(), static_cast<uint32_t>(q.size() * sizeof(int16_t))) != FA_DPI_OK) {
    return 11;
  }
  if (fa_dpi_mem_write(k_base, k.data(), static_cast<uint32_t>(k.size() * sizeof(int16_t))) != FA_DPI_OK) {
    return 12;
  }
  if (fa_dpi_mem_write(v_base, v.data(), static_cast<uint32_t>(v.size() * sizeof(int16_t))) != FA_DPI_OK) {
    return 13;
  }

  fa_task_desc_t desc{};
  desc.q_base = q_base;
  desc.k_base = k_base;
  desc.v_base = v_base;
  desc.o_base = o_base;
  desc.stride_bytes = stride_bytes;
  desc.neg_large_q8_8 = static_cast<int16_t>(neg_large_q8_8);
  desc.scale_q8_8 = static_cast<int16_t>(32);
  desc.causal_en = true;
  desc.op_type = FA_OP_ATTN;

  if (fa_dpi_submit_task(&desc) != FA_DPI_OK) {
    return 14;
  }
  if (fa_dpi_wait_idle(20000000) != FA_DPI_OK) {
    return 15;
  }
  if (fa_dpi_mem_read(o_base, o_rtl.data(), static_cast<uint32_t>(o_rtl.size() * sizeof(int16_t))) != FA_DPI_OK) {
    return 16;
  }

  int rc = fa_cmodel_attention_head(q.data(), k.data(), v.data(), seq_len, head_size,
                                    o_cmodel.data(), neg_large_q8_8, 0, cmodel_mode,
                                    -1, 0);
  if (rc != 0) {
    return 17;
  }

  int max_abs = 0;
  int sum_abs = 0;
  int count_diff = 0;
  for (int i = 0; i < head_size; ++i) {
    int diff = static_cast<int>(o_rtl[i]) - static_cast<int>(o_cmodel[i]);
    int ad = diff < 0 ? -diff : diff;
    if (ad > max_abs) {
      max_abs = ad;
    }
    sum_abs += ad;
    if (ad != 0) {
      count_diff++;
    }
  }

  max_abs_out = max_abs;
  sum_abs_out = sum_abs;
  count_diff_out = count_diff;
  return 0;
}

int main() {
  fa_dpi_init_cfg_t cfg{};
  cfg.memory_bytes = 16 * 1024 * 1024;
  cfg.fifo_depth = 4;
  cfg.wait_poll_interval_cycles = 64;
  cfg.enable_verilator = true;
  if (fa_dpi_init(&cfg) != FA_DPI_OK) {
    std::cerr << "fa_dpi_init failed\n";
    return 1;
  }

  std::mt19937 rng(20260319u);
  const int head_size = 64;
  const int neg_large_q8_8 = -8192;
  int cmodel_mode = 0;
  if (const char *env = std::getenv("CMODEL_MODE")) {
    cmodel_mode = std::atoi(env);
  }
  std::vector<int> seq_cases = {0, 1, 2, 7};

  int global_max_abs = 0;
  int global_sum_abs = 0;
  int global_diff_cnt = 0;
  int total_points = 0;

  for (int seq_len : seq_cases) {
    int case_max = 0;
    int case_sum = 0;
    int case_diff = 0;

    for (int rep = 0; rep < 8; ++rep) {
      int max_abs = 0;
      int sum_abs = 0;
      int count_diff = 0;
      int rc = run_one_case(seq_len, head_size, neg_large_q8_8, cmodel_mode, rng,
                            max_abs, sum_abs, count_diff);
      if (rc != 0) {
        fa_dpi_shutdown();
        std::cerr << "run_one_case failed rc=" << rc << " seq=" << seq_len << " rep=" << rep << "\n";
        return rc;
      }
      if (max_abs > case_max) {
        case_max = max_abs;
      }
      case_sum += sum_abs;
      case_diff += count_diff;
    }

    global_max_abs = std::max(global_max_abs, case_max);
    global_sum_abs += case_sum;
    global_diff_cnt += case_diff;
    total_points += 8 * head_size;

    std::cout << "seq_len=" << seq_len
              << " max_abs_lsb=" << case_max
              << " sum_abs=" << case_sum
              << " diff_points=" << case_diff
              << "/" << (8 * head_size)
              << "\n";
  }

  std::cout << "summary max_abs_lsb=" << global_max_abs
            << " total_sum_abs=" << global_sum_abs
            << " total_diff_points=" << global_diff_cnt
            << "/" << total_points
            << " mode=" << cmodel_mode
            << "\n";

  fa_dpi_shutdown();

  return (global_max_abs <= 1) ? 0 : 9;
}
