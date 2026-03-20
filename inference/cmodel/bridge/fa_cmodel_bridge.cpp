#include "fa_cmodel_bridge.h"

#include "attention_core.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <vector>

namespace {

inline int16_t sat_s16_local(int32_t value) {
  if (value > 32767) return 32767;
  if (value < -32768) return -32768;
  return static_cast<int16_t>(value);
}

inline int32_t div_round_nearest(int32_t numerator, int32_t denominator) {
  if (denominator <= 0) return 0;
  if (numerator >= 0) {
    return (numerator + denominator / 2) / denominator;
  }
  return (numerator - denominator / 2) / denominator;
}

int cmodel_k_smooth_enabled() {
  static int inited = 0;
  static int enabled = 0;
  if (!inited) {
    inited = 1;
    const char* env = std::getenv("FLASH_ATTN_CMODEL_K_SMOOTH");
    if (env && (std::strcmp(env, "1") == 0 ||
                std::strcmp(env, "true") == 0 ||
                std::strcmp(env, "TRUE") == 0)) {
      enabled = 1;
    }
  }
  return enabled;
}

void smooth_k_matrix(attn::MatrixI16& K) {
  const int steps = static_cast<int>(K.size());
  if (steps <= 1) return;
  const int head_size = static_cast<int>(K[0].size());

  for (int d = 0; d < head_size; ++d) {
    int32_t sum = 0;
    for (int t = 0; t < steps; ++t) {
      sum += static_cast<int32_t>(K[t][d]);
    }
    const int32_t mean = div_round_nearest(sum, steps);
    for (int t = 0; t < steps; ++t) {
      const int32_t centered = static_cast<int32_t>(K[t][d]) - mean;
      K[t][d] = sat_s16_local(centered);
    }
  }
}

} // namespace

int fa_cmodel_attention_head(const int16_t *q_head,
                             const int16_t *k_seq,
                             const int16_t *v_seq,
                             int seq_len,
                             int head_size,
                             int16_t *out_head,
                             int neg_large_q8_8,
                             int hard_mask,
                             int mode_id,
                             int layer_idx,
                             int head_idx) {
  if (!q_head || !k_seq || !v_seq || !out_head || seq_len < 0 || head_size <= 0) {
    return -1;
  }

  const int steps = seq_len + 1;
  attn::MatrixI16 Q(steps, std::vector<int16_t>(head_size, 0));
  attn::MatrixI16 K(steps, std::vector<int16_t>(head_size));
  attn::MatrixI16 V(steps, std::vector<int16_t>(head_size));

  for (int d = 0; d < head_size; ++d) {
    Q[steps - 1][d] = q_head[d];
  }

  for (int t = 0; t < steps; ++t) {
    const int base = t * head_size;
    for (int d = 0; d < head_size; ++d) {
      K[t][d] = k_seq[base + d];
      V[t][d] = v_seq[base + d];
    }
  }

  if (cmodel_k_smooth_enabled()) {
    smooth_k_matrix(K);
  }

  static int stage_trace_inited = 0;
  static int stage_trace_enabled = 0;
  static int stage_trace_mode = 15;
  static int stage_trace_layer = -1;
  static int stage_trace_head = -1;
  static int stage_trace_pos = -1;
  static FILE* stage_trace_fp = nullptr;

  if (!stage_trace_inited) {
    stage_trace_inited = 1;
    const char* trace_env = std::getenv("FLASH_ATTN_CMODEL_STAGE_TRACE");
    if (trace_env && (std::strcmp(trace_env, "1") == 0 ||
                      std::strcmp(trace_env, "true") == 0 ||
                      std::strcmp(trace_env, "TRUE") == 0)) {
      stage_trace_enabled = 1;
    }

    const char* mode_env = std::getenv("FLASH_ATTN_CMODEL_STAGE_TRACE_MODE");
    if (mode_env && mode_env[0] != '\0') {
      stage_trace_mode = std::atoi(mode_env);
    }
    const char* layer_env = std::getenv("FLASH_ATTN_CMODEL_STAGE_TRACE_LAYER");
    if (layer_env && layer_env[0] != '\0') {
      stage_trace_layer = std::atoi(layer_env);
    }
    const char* head_env = std::getenv("FLASH_ATTN_CMODEL_STAGE_TRACE_HEAD");
    if (head_env && head_env[0] != '\0') {
      stage_trace_head = std::atoi(head_env);
    }
    const char* pos_env = std::getenv("FLASH_ATTN_CMODEL_STAGE_TRACE_POS");
    if (pos_env && pos_env[0] != '\0') {
      stage_trace_pos = std::atoi(pos_env);
    }

    if (stage_trace_enabled) {
      const char* file_env = std::getenv("FLASH_ATTN_CMODEL_STAGE_TRACE_FILE");
      const char* path = (file_env && file_env[0] != '\0')
                             ? file_env
                             : "logs/cmodel_stage_trace.log";
      stage_trace_fp = std::fopen(path, "a");
    }
  }

  attn::Mode mode = attn::Mode::RTL_STRICT;
  switch (mode_id) {
    case 0: mode = attn::Mode::RTL_STRICT; break;
    case 1: mode = attn::Mode::RTL_CTX_STEP; break;
    case 2: mode = attn::Mode::RTL_CTX_STEP_ACC24; break;
    case 3: mode = attn::Mode::RTL_CTX_INTERP; break;
    case 4: mode = attn::Mode::RTL_CTX_PWL; break;
    case 5: mode = attn::Mode::RTL_CTX_REAL_EXP; break;
    case 6: mode = attn::Mode::RTL_EXACT; break;
    case 7: mode = attn::Mode::RTL_REAL_EXP; break;
    case 8: mode = attn::Mode::RTL_REAL_EXP_FLOAT_NORM; break;
    case 9: mode = attn::Mode::FLOAT_ONLINE_Q8; break;
    case 10: mode = attn::Mode::ACC_FLOAT_QOUT; break;
    case 11: mode = attn::Mode::ACC_FLOAT_REAL_EXP_QOUT; break;
    case 12: mode = attn::Mode::FIXED_HIACC_QOUT; break;
    case 13: mode = attn::Mode::FIXED_HIACC_REAL_EXP_QOUT; break;
    case 14: mode = attn::Mode::FA_CORE_COMPAT; break;
    case 15: mode = attn::Mode::FIXED_Q8_IMPROVED; break;
    case 16: mode = attn::Mode::FIXED_Q8_DUALBUF; break;
    case 17: mode = attn::Mode::FIXED_Q8_DUALBUF_C8; break;
    case 18: mode = attn::Mode::FIXED_Q8_DUALBUF_C32; break;
    default: mode = attn::Mode::RTL_STRICT; break;
  }

  auto should_trace = [&]() {
    if (!stage_trace_enabled || !stage_trace_fp) return false;
    if (stage_trace_mode >= 0 && mode_id != stage_trace_mode) return false;
    if (stage_trace_layer >= 0 && layer_idx != stage_trace_layer) return false;
    if (stage_trace_head >= 0 && head_idx != stage_trace_head) return false;
    if (stage_trace_pos >= 0 && seq_len != stage_trace_pos) return false;
    return true;
  };

  if (should_trace() && (mode_id == 15 || mode_id == 16)) {
    const int D = head_size;
    const int S = steps;
    const int16_t scale_q8_8 = static_cast<int16_t>(std::lround((1.0 / std::sqrt(static_cast<double>(D))) * 256.0));

    if (mode_id == 15) {
      int16_t m_prev = static_cast<int16_t>(-32768);
      uint32_t l_prev = 0;
      std::vector<int64_t> acc(D, 0);
      std::fprintf(stage_trace_fp, "trace_begin mode=15 layer=%d pos=%d head=%d steps=%d\n",
                   layer_idx, seq_len, head_idx, S);
      for (int kj = 0; kj < S; ++kj) {
        int64_t dp = 0;
        for (int d = 0; d < D; ++d) {
          dp += static_cast<int32_t>(Q[S - 1][d]) * static_cast<int32_t>(K[kj][d]);
        }
        int16_t dp_q8_8 = static_cast<int16_t>((dp >> 8) & 0xFFFF);
        int16_t score = attn::q8_8_mul_sat(dp_q8_8, scale_q8_8);
        int16_t m_new = (score > m_prev) ? score : m_prev;
        int16_t diff_old = static_cast<int16_t>(m_prev - m_new);
        int16_t diff_new = static_cast<int16_t>(score - m_new);
        uint16_t exp_old = attn::exp_real_q1_15(diff_old);
        uint16_t exp_new = attn::exp_real_q1_15(diff_new);

        uint32_t l_scaled = static_cast<uint32_t>((static_cast<uint64_t>(l_prev) * exp_old) >> 15);
        uint32_t l_term = static_cast<uint32_t>(exp_new) << 1;
        l_prev = attn::to_u32(static_cast<uint64_t>(l_scaled) + l_term);

        int64_t acc_abs_max = 0;
        for (int d = 0; d < D; ++d) {
          int64_t acc_old = (acc[d] * static_cast<int64_t>(exp_old)) >> 15;
          int64_t pv_term = (static_cast<int64_t>(exp_new) * static_cast<int64_t>(static_cast<int32_t>(V[kj][d]))) << 1;
          acc[d] = acc_old + pv_term;
          int64_t ad = acc[d] < 0 ? -acc[d] : acc[d];
          if (ad > acc_abs_max) acc_abs_max = ad;
        }
        std::fprintf(stage_trace_fp,
                     "stage mode=15 layer=%d pos=%d head=%d kj=%d score=%d m_old=%d m_new=%d exp_old=%u exp_new=%u l=%u acc_abs_max=%lld\n",
                     layer_idx, seq_len, head_idx, kj, score, m_prev, m_new,
                     static_cast<unsigned>(exp_old), static_cast<unsigned>(exp_new),
                     static_cast<unsigned>(l_prev), static_cast<long long>(acc_abs_max));
        m_prev = m_new;
      }
      std::fprintf(stage_trace_fp, "trace_end mode=15 layer=%d pos=%d head=%d\n",
                   layer_idx, seq_len, head_idx);
      std::fflush(stage_trace_fp);
    } else {
      constexpr int kChunk = 16;
      int16_t m_global = static_cast<int16_t>(-32768);
      uint32_t l_global = 0;
      std::vector<int64_t> acc_global(D, 0);
      std::fprintf(stage_trace_fp, "trace_begin mode=16 layer=%d pos=%d head=%d steps=%d\n",
                   layer_idx, seq_len, head_idx, S);

      for (int chunk_start = 0; chunk_start < S; chunk_start += kChunk) {
        const int chunk_end = std::min(S, chunk_start + kChunk);
        int16_t m_local = static_cast<int16_t>(-32768);
        uint32_t l_local = 0;
        std::vector<int64_t> acc_local(D, 0);

        for (int kj = chunk_start; kj < chunk_end; ++kj) {
          int64_t dp = 0;
          for (int d = 0; d < D; ++d) {
            dp += static_cast<int32_t>(Q[S - 1][d]) * static_cast<int32_t>(K[kj][d]);
          }
          int16_t dp_q8_8 = static_cast<int16_t>((dp >> 8) & 0xFFFF);
          int16_t score = attn::q8_8_mul_sat(dp_q8_8, scale_q8_8);

          int16_t m_new = (score > m_local) ? score : m_local;
          int16_t diff_old = static_cast<int16_t>(m_local - m_new);
          int16_t diff_new = static_cast<int16_t>(score - m_new);
          uint16_t exp_old = attn::exp_real_q1_15(diff_old);
          uint16_t exp_new = attn::exp_real_q1_15(diff_new);

          uint32_t l_scaled = static_cast<uint32_t>((static_cast<uint64_t>(l_local) * exp_old) >> 15);
          uint32_t l_term = static_cast<uint32_t>(exp_new) << 1;
          l_local = attn::to_u32(static_cast<uint64_t>(l_scaled) + l_term);

          int64_t acc_abs_max = 0;
          for (int d = 0; d < D; ++d) {
            int64_t acc_old = (acc_local[d] * static_cast<int64_t>(exp_old)) >> 15;
            int64_t pv_term = (static_cast<int64_t>(exp_new) * static_cast<int64_t>(static_cast<int32_t>(V[kj][d]))) << 1;
            acc_local[d] = acc_old + pv_term;
            int64_t ad = acc_local[d] < 0 ? -acc_local[d] : acc_local[d];
            if (ad > acc_abs_max) acc_abs_max = ad;
          }
          std::fprintf(stage_trace_fp,
                       "stage mode=16 layer=%d pos=%d head=%d chunk=[%d,%d) kj=%d score=%d m_local=%d l_local=%u acc_local_abs_max=%lld\n",
                       layer_idx, seq_len, head_idx, chunk_start, chunk_end, kj, score,
                       m_new, static_cast<unsigned>(l_local), static_cast<long long>(acc_abs_max));
          m_local = m_new;
        }

        if (l_local != 0) {
          if (l_global == 0) {
            m_global = m_local;
            l_global = l_local;
            for (int d = 0; d < D; ++d) {
              acc_global[d] = acc_local[d];
            }
          } else {
            int16_t m_new = (m_local > m_global) ? m_local : m_global;
            int16_t diff_global = static_cast<int16_t>(m_global - m_new);
            int16_t diff_local = static_cast<int16_t>(m_local - m_new);
            uint16_t exp_global = attn::exp_real_q1_15(diff_global);
            uint16_t exp_local = attn::exp_real_q1_15(diff_local);

            uint32_t l_g_scaled = static_cast<uint32_t>((static_cast<uint64_t>(l_global) * exp_global) >> 15);
            uint32_t l_l_scaled = static_cast<uint32_t>((static_cast<uint64_t>(l_local) * exp_local) >> 15);
            l_global = attn::to_u32(static_cast<uint64_t>(l_g_scaled) + l_l_scaled);

            for (int d = 0; d < D; ++d) {
              int64_t g_scaled = (acc_global[d] * static_cast<int64_t>(exp_global)) >> 15;
              int64_t l_scaled = (acc_local[d] * static_cast<int64_t>(exp_local)) >> 15;
              acc_global[d] = g_scaled + l_scaled;
            }
            m_global = m_new;
          }
        }

        int64_t g_abs_max = 0;
        for (int d = 0; d < D; ++d) {
          int64_t ad = acc_global[d] < 0 ? -acc_global[d] : acc_global[d];
          if (ad > g_abs_max) g_abs_max = ad;
        }
        std::fprintf(stage_trace_fp,
                     "merge mode=16 layer=%d pos=%d head=%d chunk=[%d,%d) m_global=%d l_global=%u acc_global_abs_max=%lld\n",
                     layer_idx, seq_len, head_idx, chunk_start, chunk_end, m_global,
                     static_cast<unsigned>(l_global), static_cast<long long>(g_abs_max));
      }

      std::fprintf(stage_trace_fp, "trace_end mode=16 layer=%d pos=%d head=%d\n",
                   layer_idx, seq_len, head_idx);
      std::fflush(stage_trace_fp);
    }
  }

  attn::MatrixI16 O = attn::online_rtl_like(
      Q, K, V,
      1,
      steps,
      true,
      mode,
      static_cast<int16_t>(neg_large_q8_8),
      hard_mask != 0);

  if (O.empty() || O.size() < static_cast<size_t>(steps) ||
      O[steps - 1].size() != static_cast<size_t>(head_size)) {
    return -2;
  }

  for (int d = 0; d < head_size; ++d) {
    out_head[d] = O[steps - 1][d];
  }
  return 0;
}
