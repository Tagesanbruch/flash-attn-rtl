#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#include "fa_dpi_backend.h"

namespace {

inline int16_t q_from_float_trunc(float x) {
  float scaled = x * 256.0f;
  if (scaled > 32767.0f) return 32767;
  if (scaled < -32768.0f) return -32768;
  return static_cast<int16_t>(scaled);
}

inline int16_t q_from_float_floor(float x) {
  float scaled = x * 256.0f;
  if (scaled > 32767.0f) return 32767;
  if (scaled < -32768.0f) return -32768;
  return static_cast<int16_t>(std::floor(scaled));
}

inline int16_t q_from_float_nearest(float x) {
  float scaled = x * 256.0f;
  if (scaled > 32767.0f) return 32767;
  if (scaled < -32768.0f) return -32768;
  return static_cast<int16_t>(std::lrint(scaled));
}

inline float q_to_float(int16_t x) { return static_cast<float>(x) / 256.0f; }

enum class QuantMode {
  Trunc,
  Floor,
  Nearest,
};

const char *mode_name(QuantMode mode) {
  switch (mode) {
    case QuantMode::Trunc: return "trunc";
    case QuantMode::Floor: return "floor";
    case QuantMode::Nearest: return "nearest";
    default: return "unknown";
  }
}

int16_t quantize(float x, QuantMode mode) {
  switch (mode) {
    case QuantMode::Trunc: return q_from_float_trunc(x);
    case QuantMode::Floor: return q_from_float_floor(x);
    case QuantMode::Nearest: return q_from_float_nearest(x);
    default: return q_from_float_trunc(x);
  }
}

void sw_ref_fa_mode(const int16_t *q,
                    const int16_t *k,
                    const int16_t *v,
                    int16_t *o,
                    int seq_len,
                    int head_size,
                    int kv_dim,
                    QuantMode qmode,
                    bool use_eps) {
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
      acc[i] = acc[i] * exp_factor + exp_val * q_to_float(v_row[i]);
    }
    m_prev = m_curr;
  }

  float eps = use_eps ? 1e-6f : 0.0f;
  float inv_l = 1.0f / (l_prev + eps);
  for (int i = 0; i < head_size; i++) {
    o[i] = quantize(acc[i] * inv_l, qmode);
  }
}

struct CompareResult {
  int max_abs = 0;
  int max_idx = 0;
  long long sum_abs = 0;
};

CompareResult compare_vec(const std::vector<int16_t> &rtl, const std::vector<int16_t> &ref) {
  CompareResult res;
  for (size_t i = 0; i < rtl.size(); i++) {
    int d = static_cast<int>(rtl[i]) - static_cast<int>(ref[i]);
    int ad = d < 0 ? -d : d;
    res.sum_abs += ad;
    if (ad > res.max_abs) {
      res.max_abs = ad;
      res.max_idx = static_cast<int>(i);
    }
  }
  return res;
}

} // namespace

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

  if (fa_dpi_mem_write(q_base, q.data(), static_cast<uint32_t>(q.size() * sizeof(int16_t))) != FA_DPI_OK) return 2;
  if (fa_dpi_mem_write(k_base, k.data(), static_cast<uint32_t>(k.size() * sizeof(int16_t))) != FA_DPI_OK) return 3;
  if (fa_dpi_mem_write(v_base, v.data(), static_cast<uint32_t>(v.size() * sizeof(int16_t))) != FA_DPI_OK) return 4;

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

  if (fa_dpi_submit_task(&desc) != FA_DPI_OK) return 5;
  if (fa_dpi_wait_idle(20000000) != FA_DPI_OK) return 6;
  if (fa_dpi_mem_read(o_base, o_rtl.data(), static_cast<uint32_t>(o_rtl.size() * sizeof(int16_t))) != FA_DPI_OK) return 7;

  struct Candidate { QuantMode mode; bool use_eps; };
  std::vector<Candidate> cands = {
      {QuantMode::Trunc, true},
      {QuantMode::Trunc, false},
      {QuantMode::Floor, true},
      {QuantMode::Floor, false},
      {QuantMode::Nearest, true},
      {QuantMode::Nearest, false},
  };

  int best_idx = -1;
  CompareResult best{};

  std::cout << "dpi_lsb_stage_compare seq_len=0 results\n";
  for (size_t ci = 0; ci < cands.size(); ci++) {
    std::vector<int16_t> ref(head_size, 0);
    sw_ref_fa_mode(q.data(), k.data(), v.data(), ref.data(), seq_len, head_size, kv_dim,
                   cands[ci].mode, cands[ci].use_eps);
    CompareResult r = compare_vec(o_rtl, ref);

    std::cout << "  cand=" << ci
              << " mode=" << mode_name(cands[ci].mode)
              << " eps=" << (cands[ci].use_eps ? "on" : "off")
              << " max_abs=" << r.max_abs
              << " max_idx=" << r.max_idx
              << " sum_abs=" << r.sum_abs
              << " rtl=" << static_cast<int>(o_rtl[r.max_idx])
              << " ref=" << static_cast<int>(ref[r.max_idx])
              << "\n";

    if (best_idx < 0 || r.sum_abs < best.sum_abs ||
        (r.sum_abs == best.sum_abs && r.max_abs < best.max_abs)) {
      best_idx = static_cast<int>(ci);
      best = r;
    }
  }

  std::cout << "best_candidate=" << best_idx
            << " mode=" << mode_name(cands[best_idx].mode)
            << " eps=" << (cands[best_idx].use_eps ? "on" : "off")
            << " best_max_abs=" << best.max_abs
            << " best_sum_abs=" << best.sum_abs
            << "\n";

  fa_dpi_shutdown();
  return 0;
}
