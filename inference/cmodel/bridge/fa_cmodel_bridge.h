#ifndef FA_CMODEL_BRIDGE_H
#define FA_CMODEL_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int fa_cmodel_attention_head(const int16_t *q_head,
                             const int16_t *k_seq,
                             const int16_t *v_seq,
                             int seq_len,
                             int head_size,
                             int16_t *out_head,
                             int neg_large_q8_8,
                             int hard_mask,
                             int mode_id);

#ifdef __cplusplus
}
#endif

#endif
