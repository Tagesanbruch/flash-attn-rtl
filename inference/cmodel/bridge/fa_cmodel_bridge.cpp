#include "fa_cmodel_bridge.h"

#include "attention_core.hpp"

#include <vector>

int fa_cmodel_attention_head(const int16_t *q_head,
                             const int16_t *k_seq,
                             const int16_t *v_seq,
                             int seq_len,
                             int head_size,
                             int16_t *out_head,
                             int neg_large_q8_8,
                             int hard_mask,
                             int mode_id) {
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
    default: mode = attn::Mode::RTL_STRICT; break;
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
