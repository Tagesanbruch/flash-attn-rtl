#include "fa_task_queue_submit.hpp"

#include <cstdio>

#include "fa_reg_map.hpp"

namespace fa::dpi {

namespace {

static inline uint32_t low32(uint64_t v) { return static_cast<uint32_t>(v & 0xFFFFFFFFull); }
static inline uint32_t high32(uint64_t v) { return static_cast<uint32_t>((v >> 32) & 0xFFFFFFFFull); }

} // namespace

fa_dpi_status_t read_queue_status(FaAxilDriver &driver, fa_queue_status_t &status) {
  uint32_t raw = 0;
  if (!driver.read32(REG_QUEUE_STATUS, raw)) {
    return FA_DPI_E_INTERNAL;
  }

  status.queue_empty = (raw >> 0) & 0x1;
  status.queue_full = (raw >> 1) & 0x1;
  status.queue_ready = (raw >> 2) & 0x1;
  status.queue_busy_exec = (raw >> 3) & 0x1;
  status.queue_count = (raw >> 4) & 0xF;
  status.queue_free_slots = (raw >> 8) & 0xF;
  status.queue_overflow_sticky = (raw >> 12) & 0x1;
  status.queue_underflow_sticky = (raw >> 13) & 0x1;
  status.queue_desc_error_sticky = (raw >> 14) & 0x1;
  status.scheduler_active = (raw >> 15) & 0x1;
  status.last_error = (raw >> 24) & 0xFF;
  status.reserved0 = 0;
  status.reserved1 = 0;
  status.reserved2 = 0;
  status.reserved3 = 0;
  status.reserved4 = 0;
  status.reserved5 = 0;
  return FA_DPI_OK;
}

fa_dpi_status_t submit_task_via_queue(FaAxilDriver &driver, const fa_task_desc_t &desc,
                                      uint32_t poll_timeout_cycles, uint32_t poll_step_cycles,
                                      uint32_t *accepted_count_after) {
  if (desc.op_type != FA_OP_ATTN) {
    return FA_DPI_E_UNSUPPORTED;
  }

  uint32_t accepted_before = 0;
  if (!driver.read32(REG_TASK_ACCEPT_COUNT, accepted_before)) {
    std::fprintf(stderr, "[fa_dpi] read REG_TASK_ACCEPT_COUNT before submit failed\n");
    return FA_DPI_E_INTERNAL;
  }

  uint32_t waited = 0;
  while (waited < poll_timeout_cycles) {
    fa_queue_status_t qst{};
    fa_dpi_status_t st = read_queue_status(driver, qst);
    if (st != FA_DPI_OK) {
      std::fprintf(stderr, "[fa_dpi] read queue status during ready-poll failed, st=%d\n", (int)st);
      return st;
    }
    if (qst.queue_ready) {
      break;
    }
    waited += poll_step_cycles;
  }
  if (waited >= poll_timeout_cycles) {
    std::fprintf(stderr, "[fa_dpi] queue ready poll timeout after %u cycles\n", waited);
    return FA_DPI_E_TIMEOUT;
  }

  if (!driver.write32(REG_CFG, desc.causal_en ? 1u : 0u)) {
    std::fprintf(stderr, "[fa_dpi] write CFG failed\n");
    return FA_DPI_E_INTERNAL;
  }
  if (!driver.write32(REG_Q_BASE_L, low32(desc.q_base))) { std::fprintf(stderr, "[fa_dpi] write Q_BASE_L failed\n"); return FA_DPI_E_INTERNAL; }
  if (!driver.write32(REG_Q_BASE_H, high32(desc.q_base))) { std::fprintf(stderr, "[fa_dpi] write Q_BASE_H failed\n"); return FA_DPI_E_INTERNAL; }
  if (!driver.write32(REG_K_BASE_L, low32(desc.k_base))) { std::fprintf(stderr, "[fa_dpi] write K_BASE_L failed\n"); return FA_DPI_E_INTERNAL; }
  if (!driver.write32(REG_K_BASE_H, high32(desc.k_base))) { std::fprintf(stderr, "[fa_dpi] write K_BASE_H failed\n"); return FA_DPI_E_INTERNAL; }
  if (!driver.write32(REG_V_BASE_L, low32(desc.v_base))) { std::fprintf(stderr, "[fa_dpi] write V_BASE_L failed\n"); return FA_DPI_E_INTERNAL; }
  if (!driver.write32(REG_V_BASE_H, high32(desc.v_base))) { std::fprintf(stderr, "[fa_dpi] write V_BASE_H failed\n"); return FA_DPI_E_INTERNAL; }
  if (!driver.write32(REG_O_BASE_L, low32(desc.o_base))) { std::fprintf(stderr, "[fa_dpi] write O_BASE_L failed\n"); return FA_DPI_E_INTERNAL; }
  if (!driver.write32(REG_O_BASE_H, high32(desc.o_base))) { std::fprintf(stderr, "[fa_dpi] write O_BASE_H failed\n"); return FA_DPI_E_INTERNAL; }
  if (!driver.write32(REG_STRIDE_BYTES, desc.stride_bytes)) { std::fprintf(stderr, "[fa_dpi] write STRIDE failed\n"); return FA_DPI_E_INTERNAL; }
  if (!driver.write32(REG_NEG_LARGE, static_cast<uint16_t>(desc.neg_large_q8_8))) { std::fprintf(stderr, "[fa_dpi] write NEG_LARGE failed\n"); return FA_DPI_E_INTERNAL; }
  if (!driver.write32(REG_SCALE, static_cast<uint16_t>(desc.scale_q8_8))) { std::fprintf(stderr, "[fa_dpi] write SCALE failed\n"); return FA_DPI_E_INTERNAL; }

  if (!driver.write32(REG_QUEUE_CMD, QUEUE_CMD_ENQUEUE)) {
    std::fprintf(stderr, "[fa_dpi] write QUEUE_CMD enqueue failed\n");
    return FA_DPI_E_INTERNAL;
  }

  uint32_t accepted_after = accepted_before;
  if (!driver.read32(REG_TASK_ACCEPT_COUNT, accepted_after)) {
    std::fprintf(stderr, "[fa_dpi] read REG_TASK_ACCEPT_COUNT after submit failed\n");
    return FA_DPI_E_INTERNAL;
  }
  if (accepted_count_after) {
    *accepted_count_after = accepted_after;
  }

  if (accepted_after != accepted_before + 1u) {
    fa_queue_status_t qst{};
    if (read_queue_status(driver, qst) == FA_DPI_OK && (qst.queue_desc_error_sticky || qst.queue_overflow_sticky)) {
      std::fprintf(stderr,
                   "[fa_dpi] enqueue rejected: desc_err=%u overflow=%u count=%u free=%u last_err=%u\n",
                   (unsigned)qst.queue_desc_error_sticky,
                   (unsigned)qst.queue_overflow_sticky,
                   (unsigned)qst.queue_count,
                   (unsigned)qst.queue_free_slots,
                   (unsigned)qst.last_error);
      return FA_DPI_E_QUEUE_REJECT;
    }
    std::fprintf(stderr,
                 "[fa_dpi] accept_count mismatch: before=%u after=%u (expected +1)\n",
                 accepted_before, accepted_after);
    return FA_DPI_E_INTERNAL;
  }

  return FA_DPI_OK;
}

} // namespace fa::dpi
