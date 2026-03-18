#include "flash_attn.h"
#include <math.h>
#include <omp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef FLASH_ATTN_ENABLE_DPI
#include "fa_dpi_backend.h"
#endif

static fa_backend_t g_backend = FA_BACKEND_SW;

typedef struct {
  int pos;
  int head;
  int max_abs_lsb;
  int max_idx;
  int dpi_val;
  int ref_val;
  unsigned queue_count;
  unsigned queue_free;
  unsigned queue_busy;
  unsigned queue_last_err;
  unsigned cycles;
  unsigned run_count;
  unsigned task_accept;
  unsigned task_done;
} fa_diff_trace_entry_t;

#define FA_DIFF_TRACE_RING_SIZE 512
static fa_diff_trace_entry_t g_diff_ring[FA_DIFF_TRACE_RING_SIZE];
static int g_diff_ring_write_idx = 0;
static int g_diff_total_count = 0;
static int g_diff_trace_enable = 0;
static int g_diff_assert_on_diff = 0;
static int g_diff_summary_limit = 4;
static int g_sigint_summary_dumped = 0;
static FILE *g_diff_trace_fp = NULL;
static int g_diff_cfg_inited = 0;
static volatile sig_atomic_t g_sigint_requested = 0;

static void fa_sigint_handler(int signo) {
  (void)signo;
  if (g_sigint_requested)
    return;
  g_sigint_requested = 1;
  const char msg[] = "\n[flash_attn] SIGINT received, stopping current run...\n";
  write(STDERR_FILENO, msg, sizeof(msg) - 1);
}

static void fa_diff_trace_init_once(void) {
  if (g_diff_cfg_inited)
    return;
  g_diff_cfg_inited = 1;

  const char *trace_env = getenv("FLASH_ATTN_DPI_DIFF_TRACE");
  if (trace_env && (strcmp(trace_env, "1") == 0 || strcmp(trace_env, "true") == 0 || strcmp(trace_env, "TRUE") == 0)) {
    g_diff_trace_enable = 1;
  }

  const char *assert_env = getenv("FLASH_ATTN_DPI_ASSERT_ON_DIFF");
  if (assert_env && (strcmp(assert_env, "1") == 0 || strcmp(assert_env, "true") == 0 || strcmp(assert_env, "TRUE") == 0)) {
    g_diff_assert_on_diff = 1;
  }

  const char *summary_limit_env = getenv("FLASH_ATTN_DPI_DIFF_SUMMARY_LIMIT");
  if (summary_limit_env && summary_limit_env[0] != '\0') {
    int limit = atoi(summary_limit_env);
    if (limit > 0) {
      g_diff_summary_limit = limit;
    }
  }

  if (g_diff_trace_enable) {
    const char *file_env = getenv("FLASH_ATTN_DPI_DIFF_TRACE_FILE");
    const char *path = (file_env && file_env[0] != '\0') ? file_env : "flash_attn_dpi_diff_trace.log";
    g_diff_trace_fp = fopen(path, "a");
  }

  signal(SIGINT, fa_sigint_handler);
}

static void fa_diff_trace_record(const fa_diff_trace_entry_t *entry) {
  if (!entry)
    return;

  g_diff_ring[g_diff_ring_write_idx] = *entry;
  g_diff_ring_write_idx = (g_diff_ring_write_idx + 1) % FA_DIFF_TRACE_RING_SIZE;
  g_diff_total_count++;

  if (g_diff_trace_fp) {
    fprintf(g_diff_trace_fp,
            "diff pos=%d head=%d max_abs_lsb=%d idx=%d dpi=%d ref=%d queue_count=%u queue_free=%u queue_busy=%u queue_last_err=%u cycles=%u run=%u accept=%u done=%u\n",
            entry->pos, entry->head, entry->max_abs_lsb, entry->max_idx,
            entry->dpi_val, entry->ref_val,
            entry->queue_count, entry->queue_free, entry->queue_busy,
            entry->queue_last_err, entry->cycles, entry->run_count,
            entry->task_accept, entry->task_done);
    fflush(g_diff_trace_fp);
  }
}

static void fa_diff_trace_dump_summary(const char *reason) {
  fprintf(stderr, "[flash_attn][diff-trace] summary reason=%s total_mismatch=%d ring_size=%d show_last=%d\n",
          reason ? reason : "unknown", g_diff_total_count, FA_DIFF_TRACE_RING_SIZE,
          g_diff_summary_limit);

  int available = g_diff_total_count < FA_DIFF_TRACE_RING_SIZE ? g_diff_total_count : FA_DIFF_TRACE_RING_SIZE;
  int show_count = available < g_diff_summary_limit ? available : g_diff_summary_limit;
  int start = g_diff_ring_write_idx - show_count;
  if (start < 0)
    start += FA_DIFF_TRACE_RING_SIZE;

  for (int i = 0; i < show_count; i++) {
    int idx = (start + i) % FA_DIFF_TRACE_RING_SIZE;
    fa_diff_trace_entry_t *e = &g_diff_ring[idx];
    fprintf(stderr,
            "[flash_attn][diff-trace] #%d pos=%d head=%d max_abs_lsb=%d idx=%d dpi=%d ref=%d q_count=%u q_free=%u q_busy=%u q_last=%u cyc=%u run=%u acc=%u done=%u\n",
            i, e->pos, e->head, e->max_abs_lsb, e->max_idx,
            e->dpi_val, e->ref_val,
            e->queue_count, e->queue_free, e->queue_busy, e->queue_last_err,
            e->cycles, e->run_count, e->task_accept, e->task_done);
  }
}

int flash_attention_set_backend(fa_backend_t backend) {
  if (backend != FA_BACKEND_SW && backend != FA_BACKEND_DPI)
    return -1;
#ifndef FLASH_ATTN_ENABLE_DPI
  if (backend == FA_BACKEND_DPI)
    return -1;
#endif
  g_backend = backend;
  return 0;
}

fa_backend_t flash_attention_get_backend(void) { return g_backend; }

int flash_attention_sigint_requested(void) { return g_sigint_requested ? 1 : 0; }

static void flash_attention_backend_env_once(void) {
  static int env_checked = 0;
  if (env_checked)
    return;
  env_checked = 1;

  const char *env_backend = getenv("FLASH_ATTN_BACKEND");
  if (!env_backend)
    return;

  if (strcmp(env_backend, "dpi") == 0 || strcmp(env_backend, "DPI") == 0) {
#ifdef FLASH_ATTN_ENABLE_DPI
    g_backend = FA_BACKEND_DPI;
#else
    g_backend = FA_BACKEND_SW;
#endif
  } else if (strcmp(env_backend, "sw") == 0 || strcmp(env_backend, "SW") == 0) {
    g_backend = FA_BACKEND_SW;
  }
}

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
  flash_attention_backend_env_once();

#ifdef FLASH_ATTN_ENABLE_DPI
  if (g_backend == FA_BACKEND_DPI) {
    fa_diff_trace_init_once();

    static int dpi_ready = 0;
    static int dpi_failed = 0;
    int enable_difftest = 1;
    int diff_print_enable = 0;
    const char *difftest_env = getenv("FLASH_ATTN_DPI_DIFFTEST");
    if (difftest_env && (strcmp(difftest_env, "0") == 0 || strcmp(difftest_env, "false") == 0 || strcmp(difftest_env, "FALSE") == 0)) {
      enable_difftest = 0;
    }
    const char *diff_print_env = getenv("FLASH_ATTN_DPI_DIFF_PRINT");
    if (diff_print_env && (strcmp(diff_print_env, "1") == 0 || strcmp(diff_print_env, "true") == 0 || strcmp(diff_print_env, "TRUE") == 0)) {
      diff_print_enable = 1;
    }

    if (!dpi_ready && !dpi_failed) {
      fa_dpi_init_cfg_t cfg = {0};
      cfg.memory_bytes = 16 * 1024 * 1024;
      cfg.fifo_depth = 4;
      cfg.wait_poll_interval_cycles = 64;
      cfg.verbose = false;
      cfg.enable_verilator = false;
      if (fa_dpi_init(&cfg) == FA_DPI_OK) {
        dpi_ready = 1;
      } else {
        dpi_failed = 1;
      }
    }

    if (dpi_ready) {
      const uint64_t q_base = 0x00000000ull;
      const uint64_t k_base = 0x00001000ull;
      const uint64_t v_base = 0x00002000ull;
      const uint64_t o_base = 0x00003000ull;
      const uint32_t stride_bytes = (uint32_t)(head_size * sizeof(q8_8_t));
      const uint32_t tensor_bytes = (uint32_t)(head_size * sizeof(q8_8_t));
      const int kv_steps = seq_len + 1;
      q8_8_t *k_head = (q8_8_t *)malloc((size_t)kv_steps * (size_t)head_size * sizeof(q8_8_t));
      q8_8_t *v_head = (q8_8_t *)malloc((size_t)kv_steps * (size_t)head_size * sizeof(q8_8_t));
      q8_8_t *o_head = (q8_8_t *)malloc((size_t)head_size * sizeof(q8_8_t));
      q8_8_t *o_ref = (q8_8_t *)malloc((size_t)head_size * sizeof(q8_8_t));

      int16_t scale_q8_8 = float_to_q8_8(scale);
      if (scale_q8_8 == 0) {
        scale_q8_8 = (int16_t)32;
      }

      int dpi_ok = 1;
      for (int h = 0; h < n_heads && dpi_ok; h++) {
        if (g_sigint_requested) {
          if (!g_sigint_summary_dumped) {
            fa_diff_trace_dump_summary("sigint");
            fflush(stderr);
            g_sigint_summary_dumped = 1;
          }
          break;
        }

        if (enable_difftest) {
          fa_core_q8_8(q_hw + h * head_size, k_hw, v_hw, o_ref,
                       seq_len, head_size, h, kv_mul, kv_dim);
        }

        int kv_head_idx = h / kv_mul;
        for (int t = 0; t < kv_steps; t++) {
          q8_8_t *k_src = k_hw + t * kv_dim + kv_head_idx * head_size;
          q8_8_t *v_src = v_hw + t * kv_dim + kv_head_idx * head_size;
          memcpy(k_head + (size_t)t * head_size, k_src, (size_t)head_size * sizeof(q8_8_t));
          memcpy(v_head + (size_t)t * head_size, v_src, (size_t)head_size * sizeof(q8_8_t));
        }

        if (fa_dpi_mem_write(q_base, q_hw + h * head_size, tensor_bytes) != FA_DPI_OK)
          dpi_ok = 0;
        if (dpi_ok && fa_dpi_mem_write(k_base, k_head, (uint32_t)((size_t)kv_steps * tensor_bytes)) != FA_DPI_OK)
          dpi_ok = 0;
        if (dpi_ok && fa_dpi_mem_write(v_base, v_head, (uint32_t)((size_t)kv_steps * tensor_bytes)) != FA_DPI_OK)
          dpi_ok = 0;

        fa_task_desc_t desc = {0};
        desc.q_base = q_base;
        desc.k_base = k_base;
        desc.v_base = v_base;
        desc.o_base = o_base;
        desc.stride_bytes = stride_bytes;
        desc.neg_large_q8_8 = (int16_t)-8192;
        desc.scale_q8_8 = scale_q8_8;
        desc.causal_en = true;
        desc.op_type = FA_OP_ATTN;

        if (dpi_ok && fa_dpi_submit_task(&desc) != FA_DPI_OK)
          dpi_ok = 0;
        if (dpi_ok && fa_dpi_wait_idle(1000000) != FA_DPI_OK)
          dpi_ok = 0;
        if (dpi_ok && fa_dpi_mem_read(o_base, o_head, tensor_bytes) != FA_DPI_OK)
          dpi_ok = 0;

        if (dpi_ok) {
          memcpy(o_hw + h * head_size, o_head, tensor_bytes);

          if (enable_difftest) {
            int max_abs_lsb = 0;
            int max_idx = 0;
            for (int i = 0; i < head_size; i++) {
              int diff = (int)o_head[i] - (int)o_ref[i];
              int abs_diff = diff < 0 ? -diff : diff;
              if (abs_diff > max_abs_lsb) {
                max_abs_lsb = abs_diff;
                max_idx = i;
              }
            }

            if (max_abs_lsb != 0) {
              fa_queue_status_t qst = {0};
              fa_perf_snapshot_t perf = {0};
              fa_dpi_get_queue_status(&qst);
              fa_dpi_read_perf(&perf);

              fa_diff_trace_entry_t entry;
              memset(&entry, 0, sizeof(entry));
              entry.pos = seq_len;
              entry.head = h;
              entry.max_abs_lsb = max_abs_lsb;
              entry.max_idx = max_idx;
              entry.dpi_val = (int)o_head[max_idx];
              entry.ref_val = (int)o_ref[max_idx];
              entry.queue_count = (unsigned)qst.queue_count;
              entry.queue_free = (unsigned)qst.queue_free_slots;
              entry.queue_busy = (unsigned)qst.queue_busy_exec;
              entry.queue_last_err = (unsigned)qst.last_error;
              entry.cycles = (unsigned)perf.cycles;
              entry.run_count = (unsigned)perf.run_count;
              entry.task_accept = (unsigned)perf.task_accept_count;
              entry.task_done = (unsigned)perf.task_done_count;
              fa_diff_trace_record(&entry);

                    if (g_diff_assert_on_diff || diff_print_enable) {
                fprintf(stderr,
                  "[flash_attn][dpi-difftest] mismatch detected: head=%d pos=%d max_abs_lsb=%d at idx=%d dpi=%d ref=%d\n",
                  h, seq_len, max_abs_lsb, max_idx, (int)o_head[max_idx], (int)o_ref[max_idx]);
                fprintf(stderr,
                  "[flash_attn][dpi-difftest] queue: empty=%u full=%u ready=%u busy=%u count=%u free=%u overflow=%u underflow=%u desc_err=%u last_err=%u\n",
                  (unsigned)qst.queue_empty, (unsigned)qst.queue_full,
                  (unsigned)qst.queue_ready, (unsigned)qst.queue_busy_exec,
                  (unsigned)qst.queue_count, (unsigned)qst.queue_free_slots,
                  (unsigned)qst.queue_overflow_sticky,
                  (unsigned)qst.queue_underflow_sticky,
                  (unsigned)qst.queue_desc_error_sticky,
                  (unsigned)qst.last_error);
                fprintf(stderr,
                  "[flash_attn][dpi-difftest] perf: cycles=%u run=%u busy=%u rd_cmd=%u rd_beat=%u wr_cmd=%u wr_beat=%u comp=%u accept=%u done=%u err=%u last_err=%u\n",
                  (unsigned)perf.cycles, (unsigned)perf.run_count,
                  (unsigned)perf.busy_cycles,
                  (unsigned)perf.dma_rd_cmd_count,
                  (unsigned)perf.dma_rd_beat_count,
                  (unsigned)perf.dma_wr_cmd_count,
                  (unsigned)perf.dma_wr_beat_count,
                  (unsigned)perf.comp_launch_count,
                  (unsigned)perf.task_accept_count,
                  (unsigned)perf.task_done_count,
                  (unsigned)perf.task_error_count,
                  (unsigned)perf.last_error);
                    }
              if (g_diff_assert_on_diff) {
                fa_diff_trace_dump_summary("assert_on_diff");
                fflush(stderr);
                _Exit(2);
              }
            }
          }
        }
      }

      free(k_head);
      free(v_head);
      free(o_head);
      free(o_ref);

      if (g_sigint_requested && !g_sigint_summary_dumped) {
        fa_diff_trace_dump_summary("sigint");
        fflush(stderr);
        g_sigint_summary_dumped = 1;
      }

      if (!dpi_ok) {
        g_backend = FA_BACKEND_SW;
      }
    } else {
      g_backend = FA_BACKEND_SW;
    }
  }
#endif

  if (g_backend == FA_BACKEND_SW) {
    int h;
#pragma omp parallel for private(h)
    for (h = 0; h < n_heads; h++) {
      fa_core_q8_8(q_hw + h * head_size, k_hw, v_hw, o_hw + h * head_size,
                   seq_len, head_size, h, kv_mul, kv_dim);
    }
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
