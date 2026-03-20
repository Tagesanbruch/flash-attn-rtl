#include "fa_cmodel_bridge.h"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>
#include <vector>

static inline float q8_8_to_float(int16_t x) {
  return static_cast<float>(x) / 256.0f;
}

static inline int16_t float_to_q8_8(float x) {
  float scaled = x * 256.0f;
  if (scaled > 32767.0f) return 32767;
  if (scaled < -32768.0f) return -32768;
  return static_cast<int16_t>(scaled);
}

static void fa_core_ref(const int16_t *q,
                        const int16_t *k,
                        const int16_t *v,
                        int16_t *o,
                        int seq_len,
                        int head_size) {
  float m_prev = -1e20f;
  float l_prev = 0.0f;
  std::vector<float> acc(head_size, 0.0f);
  float scale = 1.0f / std::sqrt(static_cast<float>(head_size));

  for (int t = 0; t <= seq_len; ++t) {
    int32_t score_acc = 0;
    const int16_t *k_row = k + t * head_size;
    const int16_t *v_row = v + t * head_size;

    for (int i = 0; i < head_size; ++i) {
      score_acc += static_cast<int32_t>(q[i]) * static_cast<int32_t>(k_row[i]);
    }

    float score = (static_cast<float>(score_acc) / 65536.0f) * scale;
    float m_curr = score > m_prev ? score : m_prev;
    float exp_val = std::exp(score - m_curr);
    float exp_factor = std::exp(m_prev - m_curr);

    l_prev = l_prev * exp_factor + exp_val;
    for (int i = 0; i < head_size; ++i) {
      acc[i] = acc[i] * exp_factor + exp_val * q8_8_to_float(v_row[i]);
    }
    m_prev = m_curr;
  }

  float inv_l = 1.0f / (l_prev + 1e-6f);
  for (int i = 0; i < head_size; ++i) {
    o[i] = float_to_q8_8(acc[i] * inv_l);
  }
}

int main() {
  const int head_size = 64;
  const int neg_large = -8192;
  const int repeats = 64;
  const int modes[] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18};
  const int seq_cases[] = {0,1,2,7,31,63};

  std::mt19937 rng(20260319u);
  std::uniform_int_distribution<int> dist(-192, 192);

  for (int mode : modes) {
    long long sum_abs = 0;
    int max_abs = 0;
    long long diff_cnt = 0;
    long long total_cnt = 0;

    for (int seq_len : seq_cases) {
      const int steps = seq_len + 1;
      std::vector<int16_t> q(head_size);
      std::vector<int16_t> k(steps * head_size);
      std::vector<int16_t> v(steps * head_size);
      std::vector<int16_t> o_ref(head_size);
      std::vector<int16_t> o_cm(head_size);

      for (int rep = 0; rep < repeats; ++rep) {
        for (int i = 0; i < head_size; ++i) q[i] = static_cast<int16_t>(dist(rng));
        for (int i = 0; i < steps * head_size; ++i) {
          k[i] = static_cast<int16_t>(dist(rng));
          v[i] = static_cast<int16_t>(dist(rng));
        }

        fa_core_ref(q.data(), k.data(), v.data(), o_ref.data(), seq_len, head_size);
        int rc = fa_cmodel_attention_head(q.data(), k.data(), v.data(), seq_len,
                                          head_size, o_cm.data(), neg_large, 0, mode,
                                          -1, 0);
        if (rc != 0) {
          std::cerr << "mode=" << mode << " rc=" << rc << "\n";
          return 1;
        }

        for (int i = 0; i < head_size; ++i) {
          int d = static_cast<int>(o_cm[i]) - static_cast<int>(o_ref[i]);
          int ad = d < 0 ? -d : d;
          sum_abs += ad;
          total_cnt++;
          if (ad > max_abs) max_abs = ad;
          if (ad != 0) diff_cnt++;
        }
      }
    }

    double mae = total_cnt ? static_cast<double>(sum_abs) / static_cast<double>(total_cnt) : 0.0;
    std::cout << "mode=" << mode
              << " mae_lsb=" << mae
              << " max_abs_lsb=" << max_abs
              << " diff_ratio=" << (total_cnt ? static_cast<double>(diff_cnt) / static_cast<double>(total_cnt) : 0.0)
              << "\n";
  }

  return 0;
}
