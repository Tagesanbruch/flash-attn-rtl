#ifndef FA_DPI_TYPES_H
#define FA_DPI_TYPES_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  FA_DPI_OK = 0,
  FA_DPI_E_NOT_INIT = 1,
  FA_DPI_E_BAD_ARG = 2,
  FA_DPI_E_TIMEOUT = 3,
  FA_DPI_E_QUEUE_REJECT = 4,
  FA_DPI_E_INTERNAL = 5,
  FA_DPI_E_UNSUPPORTED = 6
} fa_dpi_status_t;

typedef enum {
  FA_OP_ATTN = 0,
  FA_OP_GEMV = 1,
  FA_OP_GEMM = 2
} fa_op_type_t;

typedef struct {
  uint32_t memory_bytes;
  uint32_t fifo_depth;
  uint32_t wait_poll_interval_cycles;
  bool verbose;
  bool enable_verilator;
} fa_dpi_init_cfg_t;

typedef struct {
  uint64_t q_base;
  uint64_t k_base;
  uint64_t v_base;
  uint64_t o_base;
  uint32_t stride_bytes;
  int16_t neg_large_q8_8;
  int16_t scale_q8_8;
  bool causal_en;
  uint8_t op_type;
  uint8_t reserved0;
  uint16_t reserved1;

  uint64_t a_base;
  uint64_t b_base;
  uint64_t c_base;
  uint16_t m;
  uint16_t n;
  uint16_t k;
  uint16_t lda;
  uint16_t ldb;
  uint16_t ldc;
  uint16_t flags;
} fa_task_desc_t;

typedef struct {
  uint8_t queue_empty;
  uint8_t queue_full;
  uint8_t queue_ready;
  uint8_t queue_busy_exec;
  uint8_t queue_count;
  uint8_t queue_free_slots;
  uint8_t queue_overflow_sticky;
  uint8_t queue_underflow_sticky;
  uint8_t queue_desc_error_sticky;
  uint8_t scheduler_active;
  uint8_t reserved0;
  uint8_t reserved1;
  uint8_t reserved2;
  uint8_t reserved3;
  uint8_t reserved4;
  uint8_t reserved5;
  uint32_t last_error;
} fa_queue_status_t;

typedef struct {
  uint32_t cycles;
  uint32_t run_count;
  uint32_t busy_cycles;
  uint32_t dma_rd_cmd_count;
  uint32_t dma_rd_beat_count;
  uint32_t dma_wr_cmd_count;
  uint32_t dma_wr_beat_count;
  uint32_t comp_launch_count;
  uint32_t task_accept_count;
  uint32_t task_done_count;
  uint32_t task_error_count;
  uint32_t last_error;
} fa_perf_snapshot_t;

#ifdef __cplusplus
}
#endif

#endif
