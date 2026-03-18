#ifndef FLASH_ATTN_H
#define FLASH_ATTN_H

#include <stdint.h>

// 定点类型别名，匹配硬件位宽
typedef int16_t q8_8_t;  // [-128.0, 127.996]
typedef int32_t acc32_t; // 累加器

typedef enum {
  FA_BACKEND_SW = 0,
  FA_BACKEND_DPI = 1,
} fa_backend_t;

// Q8.8 格式互相转换的宏和辅助函数
static inline q8_8_t float_to_q8_8(float val) {
  float scaled = val * 256.0f;
  // 饱和截断
  if (scaled > 32767.0f)
    return 32767;
  if (scaled < -32768.0f)
    return -32768;
  return (q8_8_t)scaled;
}

static inline float q8_8_to_float(q8_8_t val) { return (float)val / 256.0f; }

// 模拟 RTL IP 核心接口
void fa_core_q8_8(
    q8_8_t *q,       // 单个 head 的 query [head_size]
    q8_8_t *k_cache, // 所有 seq 的 key [seq_len][n_kv_heads][head_size]
                     // 实际步长根据 kv_mul 而定
    q8_8_t *v_cache, // 所有 seq 的 value
    q8_8_t *att_out, // 输出 [head_size]
    int seq_len, int head_size, int head_idx, int kv_mul, int kv_dim);

// 为 C 语言原推导 `runperf.c` / `run.c` 设计的胶水函数
void flash_attention_forward(
    float *q_f32,       // [n_heads, head_size]
    float *k_cache_f32, // [S_max, n_kv_heads, head_size]
    float *v_cache_f32, // [S_max, n_kv_heads, head_size]
    float *att_out_f32, // [n_heads, head_size] 也是 `s->xb` 的起始地址
    int seq_len, int n_heads, int head_size, int kv_mul, int kv_dim,
    float scale // 1 / sqrt(head_size)
);

int flash_attention_set_backend(fa_backend_t backend);
fa_backend_t flash_attention_get_backend(void);
int flash_attention_sigint_requested(void);

#endif // FLASH_ATTN_H
