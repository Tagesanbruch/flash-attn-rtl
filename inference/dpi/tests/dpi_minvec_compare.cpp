#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>

#include "fa_dpi_backend.h"

static inline int16_t sat_s16(int v) {
  if (v > 32767) return 32767;
  if (v < -32768) return -32768;
  return static_cast<int16_t>(v);
}

static inline int16_t float_to_q8_8(float x) {
  float scaled = x * 256.0f;
  if (scaled > 32767.0f) return 32767;
  if (scaled < -32768.0f) return -32768;
  return static_cast<int16_t>(scaled);
}

static inline float q8_8_to_float(int16_t x) { return static_cast<float>(x) / 256.0f; }

static void sw_ref_fa(const int16_t *q, const int16_t *k, const int16_t *v, int16_t *o,
                      int seq_len, int head_size, int kv_dim) {
  float m_prev = -1e20f;
  float l_prev = 0.0f;
  std::vector<float> acc(head_size, 0.0f);
  float scale = 1.0f / std::sqrt(static_cast<float>(head_size));

  for (int t = 0; t <= seq_len; t++) {
    int32_t score_acc = 0;
    const int16_t *k_row = k + t * kv_dim;
    const int16_t *v_row = v + t * kv_dim;

    for (int i = 0; i < head_size; i++) {
      score_acc += static_cast<int32_t>(q[i]) * static_cast<int32_t>(k_row[i]);
    }

    float score = (static_cast<float>(score_acc) / 65536.0f) * scale;
    float m_curr = score > m_prev ? score : m_prev;
    float exp_val = std::exp(score - m_curr);
    float exp_factor = std::exp(m_prev - m_curr);

    l_prev = l_prev * exp_factor + exp_val;
    for (int i = 0; i < head_size; i++) {
      acc[i] = acc[i] * exp_factor + exp_val * q8_8_to_float(v_row[i]);
    }
    m_prev = m_curr;
  }

  float inv_l = 1.0f / (l_prev + 1e-6f);
  for (int i = 0; i < head_size; i++) {
    o[i] = float_to_q8_8(acc[i] * inv_l);
  }
}

int main() {
  const int head_size = 64;
  const int seq_len = 0;
  const int kv_dim = 64;
  const int kv_steps = seq_len + 1;
  const uint32_t stride_bytes = head_size * 2;

  const uint64_t q_base = 0x00000000ull;
  const uint64_t k_base = 0x00001000ull;
  const uint64_t v_base = 0x00002000ull;
  const uint64_t o_base = 0x00003000ull;

  std::vector<int16_t> q(head_size);
  std::vector<int16_t> k(kv_steps * kv_dim);
  std::vector<int16_t> v(kv_steps * kv_dim);
  std::vector<int16_t> o_rtl(head_size, 0);
  std::vector<int16_t> o_ref(head_size, 0);

  for (int i = 0; i < head_size; i++) {
    q[i] = static_cast<int16_t>((i % 17) - 8);
  }
  for (int t = 0; t < kv_steps; t++) {
    for (int i = 0; i < kv_dim; i++) {
      k[t * kv_dim + i] = static_cast<int16_t>(((i + t) % 13) - 6);
      v[t * kv_dim + i] = static_cast<int16_t>(((i * 3 + t) % 19) - 9);
    }
  }

  fa_dpi_init_cfg_t cfg{};
  cfg.memory_bytes = 16 * 1024 * 1024;
  cfg.fifo_depth = 4;
  cfg.wait_poll_interval_cycles = 64;
  cfg.enable_verilator = true;
  if (fa_dpi_init(&cfg) != FA_DPI_OK) {
    std::cerr << "fa_dpi_init failed\n";
    return 1;
  }

  if (fa_dpi_mem_write(q_base, q.data(), static_cast<uint32_t>(q.size() * sizeof(int16_t))) != FA_DPI_OK) {
    std::cerr << "mem_write q failed\n";
    return 2;
  }
  if (fa_dpi_mem_write(k_base, k.data(), static_cast<uint32_t>(k.size() * sizeof(int16_t))) != FA_DPI_OK) {
    std::cerr << "mem_write k failed\n";
    return 3;
  }
  if (fa_dpi_mem_write(v_base, v.data(), static_cast<uint32_t>(v.size() * sizeof(int16_t))) != FA_DPI_OK) {
    std::cerr << "mem_write v failed\n";
    return 4;
  }

  fa_task_desc_t desc{};
  desc.q_base = q_base;
  desc.k_base = k_base;
  desc.v_base = v_base;
  desc.o_base = o_base;
  desc.stride_bytes = stride_bytes;
  desc.neg_large_q8_8 = static_cast<int16_t>(-8192);
  desc.scale_q8_8 = static_cast<int16_t>(32);
  desc.causal_en = true;
  desc.op_type = FA_OP_ATTN;

  if (fa_dpi_submit_task(&desc) != FA_DPI_OK) {
    std::cerr << "submit failed\n";
    return 5;
  }
  if (fa_dpi_wait_idle(20000000) != FA_DPI_OK) {
    std::cerr << "wait idle failed\n";
    return 6;
  }
  if (fa_dpi_mem_read(o_base, o_rtl.data(), static_cast<uint32_t>(o_rtl.size() * sizeof(int16_t))) != FA_DPI_OK) {
    std::cerr << "mem_read o failed\n";
    return 7;
  }

  sw_ref_fa(q.data(), k.data(), v.data(), o_ref.data(), seq_len, head_size, kv_dim);

  int max_abs = 0;
  int max_idx = 0;
  for (int i = 0; i < head_size; i++) {
    int d = static_cast<int>(o_rtl[i]) - static_cast<int>(o_ref[i]);
    int ad = d < 0 ? -d : d;
    if (ad > max_abs) {
      max_abs = ad;
      max_idx = i;
    }
  }

  fa_perf_snapshot_t perf{};
  fa_dpi_read_perf(&perf);
  std::cout << "dpi_minvec_compare: max_abs_lsb=" << max_abs
            << " idx=" << max_idx
            << " rtl=" << static_cast<int>(o_rtl[max_idx])
            << " ref=" << static_cast<int>(o_ref[max_idx])
            << " cycles=" << perf.cycles
            << " run=" << perf.run_count
            << " accept=" << perf.task_accept_count
            << " done=" << perf.task_done_count
            << "\n";

  if (max_abs != 0) {
    std::cout << "first16 rtl/ref:";
    for (int i = 0; i < 16; i++) {
      std::cout << " [" << i << ":" << static_cast<int>(o_rtl[i]) << "/" << static_cast<int>(o_ref[i]) << "]";
    }
    std::cout << "\n";
  }

  fa_dpi_shutdown();
  return (max_abs == 0) ? 0 : 8;
}
