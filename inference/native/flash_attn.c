#include "flash_attn.h"
#include <math.h>
#include <omp.h>
#include <stdlib.h>
#include <string.h>

// Core RTL Simulation
void fa_core_q8_8(q8_8_t *q, q8_8_t *k_cache, q8_8_t *v_cache, q8_8_t *att_out,
                  int seq_len, int head_size, int head_idx, int kv_mul,
                  int kv_dim) {
  // Online Softmax State variables
  // For RTL emulation, these need enough precision to avoid overflow
  // During typical FP32 standard execution, M is float. Here we keep
  // score_acc in integer/fixed-point, and m in equivalent scale.
  float m_prev = -1e20f; // -inf equivalent
  float l_prev = 0.0f;
  float *O_float = (float *)calloc(head_size, sizeof(float));

  float scale = 1.0f / sqrtf((float)head_size);

  for (int t = 0; t <= seq_len; t++) {
    // Dot Product of Q and K[t]
    // Hardware accumulators for Q*k are typically 32/40 bits
    acc32_t score_acc = 0;

    // locate the k and v vectors for this timestep and head
    int kv_head_idx = head_idx / kv_mul;
    q8_8_t *k = k_cache + t * kv_dim + kv_head_idx * head_size;
    q8_8_t *v = v_cache + t * kv_dim + kv_head_idx * head_size;

    for (int i = 0; i < head_size; i++) {
      // (Q8.8 * Q8.8) -> Q16.16
      score_acc += (acc32_t)q[i] * (acc32_t)k[i];
    }

    // The exact RTL implementation of scaling, exponential and reciprocal might
    // be approximated. For baseline Q8.8 compatibility evaluation, we compute
    // score in floating point but preserve the bounds of Q8.8 inputs.
    // (score_acc is currently Q16.16, we back it out to float space for the
    // nonlinear math)
    float score_f32 = ((float)score_acc / 65536.0f) * scale;

    // Update max
    float m_curr = (score_f32 > m_prev) ? score_f32 : m_prev;

    // Exponentiate
    float exp_val = expf(score_f32 - m_curr);
    float exp_factor = expf(m_prev - m_curr);

    l_prev = l_prev * exp_factor + exp_val;

    // In flash attention, O is updated as O_curr = O_prev * exp_factor + V_curr
    // * exp_val
    for (int i = 0; i < head_size; i++) {
      float v_f32 = q8_8_to_float(v[i]);
      O_float[i] = O_float[i] * exp_factor + exp_val * v_f32;
    }

    m_prev = m_curr;
  }

  // Final Normalize: O = O / l_prev; and Quantize back to Q8.8
  float inv_l = 1.0f / (l_prev + 1e-6f); // protection
  for (int i = 0; i < head_size; i++) {
    O_float[i] *= inv_l;
    att_out[i] = float_to_q8_8(O_float[i]);
  }

  free(O_float);
}

void flash_attention_forward(float *q_f32, float *k_cache_f32,
                             float *v_cache_f32, float *att_out_f32,
                             int seq_len, int n_heads, int head_size,
                             int kv_mul, int kv_dim, float scale) {
  // 1. Allocate Q8.8 Buffers (These represent the SRAMs or exact DMA
  // transaction boundaries) S_max = seq_len + 1 for online softmax up to
  // current prompt token
  int S = seq_len + 1;

  // Total sizes
  size_t q_size = n_heads * head_size;
  size_t k_size = S * kv_dim;
  size_t v_size = S * kv_dim;

  q8_8_t *q_hw = (q8_8_t *)malloc(q_size * sizeof(q8_8_t));
  q8_8_t *k_hw = (q8_8_t *)malloc(k_size * sizeof(q8_8_t));
  q8_8_t *v_hw = (q8_8_t *)malloc(v_size * sizeof(q8_8_t));
  q8_8_t *o_hw = (q8_8_t *)malloc(q_size * sizeof(q8_8_t));

  // 2. Quantize Input Tensors (Float32 -> Q8.8)
  for (int i = 0; i < q_size; i++)
    q_hw[i] = float_to_q8_8(q_f32[i]);
  for (int i = 0; i < k_size; i++)
    k_hw[i] = float_to_q8_8(k_cache_f32[i]);
  for (int i = 0; i < v_size; i++)
    v_hw[i] = float_to_q8_8(v_cache_f32[i]);

  // 3. Execute IP Logic (Parallel across heads like SoC dispatching DMA
  // streams)
  int h;
#pragma omp parallel for private(h)
  for (h = 0; h < n_heads; h++) {
    fa_core_q8_8(q_hw + h * head_size, k_hw, v_hw, o_hw + h * head_size,
                 seq_len, head_size, h, kv_mul, kv_dim);
  }

  // 4. Dequantize Output Tensors (Q8.8 -> Float32)
  for (int i = 0; i < q_size; i++) {
    att_out_f32[i] = q8_8_to_float(o_hw[i]);
  }

  free(q_hw);
  free(k_hw);
  free(v_hw);
  free(o_hw);
}
