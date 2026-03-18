#include "fa_veri_top.hpp"

#include <algorithm>
#include <cstdint>
#include <memory>

#include "fa_reg_map.hpp"

namespace fa::dpi {

struct FaVeriTop::Impl {
  fa_dpi_init_cfg_t cfg{};
  bool inited = false;

  std::unique_ptr<FaDmaMemModel> mem;

  uint64_t q_base = 0;
  uint64_t k_base = 0;
  uint64_t v_base = 0;
  uint64_t o_base = 0;
  uint32_t stride_bytes = 128;
  int16_t neg_large_q8_8 = static_cast<int16_t>(0x8000);
  int16_t scale_q8_8 = 32;
  bool causal_en = false;

  uint32_t fifo_depth = 4;
  uint32_t queue_count = 0;
  bool queue_overflow_sticky = false;
  bool queue_underflow_sticky = false;
  bool queue_desc_error_sticky = false;

  bool busy_exec = false;
  bool done_sticky = false;
  uint32_t last_error = 0;

  uint32_t task_accept_count = 0;
  uint32_t task_done_count = 0;
  uint32_t task_error_count = 0;

  uint32_t run_count = 0;
  uint32_t busy_cycles = 0;
  uint32_t cycles_reg = 0;

  uint32_t active_task_cycles = 0;
  uint32_t active_task_target = 0;

  bool desc_aligned() const {
    const bool addr_align = ((q_base & 0xFULL) == 0) && ((k_base & 0xFULL) == 0) &&
                            ((v_base & 0xFULL) == 0) && ((o_base & 0xFULL) == 0);
    return addr_align && ((stride_bytes & 0xF) == 0);
  }

  bool desc_valid() const {
    return (stride_bytes != 0) && (scale_q8_8 != 0) && desc_aligned();
  }

  bool run_busy() const { return busy_exec || (queue_count != 0); }

  void maybe_launch_active_task() {
    if (!busy_exec && queue_count > 0) {
      queue_count--;
      busy_exec = true;
      active_task_cycles = 0;
      active_task_target = 2000;
    }
  }

  void on_enqueue_pulse() {
    if (!desc_valid()) {
      queue_desc_error_sticky = true;
      last_error = 3;
      return;
    }

    if (queue_count >= fifo_depth) {
      queue_overflow_sticky = true;
      last_error = 1;
      return;
    }

    if (!run_busy()) {
      run_count++;
      done_sticky = false;
    }

    queue_count++;
    task_accept_count++;
    maybe_launch_active_task();
  }

  void on_flush_pulse() {
    if (queue_count == 0 && !busy_exec) {
      queue_underflow_sticky = true;
      last_error = 2;
      return;
    }
    queue_count = 0;
  }

  uint32_t build_queue_status() const {
    const uint32_t queue_empty = (queue_count == 0) ? 1u : 0u;
    const uint32_t queue_full = (queue_count >= fifo_depth) ? 1u : 0u;
    const uint32_t queue_ready = queue_full ? 0u : 1u;
    const uint32_t free_slots = fifo_depth > queue_count ? (fifo_depth - queue_count) : 0u;
    const uint32_t busy = run_busy() ? 1u : 0u;
    const uint32_t status =
        ((last_error & 0xFFu) << 24) |
        (busy << 15) |
        ((queue_desc_error_sticky ? 1u : 0u) << 14) |
        ((queue_underflow_sticky ? 1u : 0u) << 13) |
        ((queue_overflow_sticky ? 1u : 0u) << 12) |
        ((free_slots & 0xFu) << 8) |
        ((queue_count & 0xFu) << 4) |
        ((busy_exec ? 1u : 0u) << 3) |
        (queue_ready << 2) |
        (queue_full << 1) |
        queue_empty;
    return status;
  }
};

FaVeriTop::FaVeriTop() : impl_(std::make_unique<Impl>()) {}
FaVeriTop::~FaVeriTop() { shutdown(); }

bool FaVeriTop::init(const fa_dpi_init_cfg_t &cfg) {
  impl_->cfg = cfg;
  impl_->fifo_depth = std::clamp<uint32_t>(cfg.fifo_depth, 1, 15);
  const uint32_t mem_bytes = cfg.memory_bytes == 0 ? (64u * 1024u * 1024u) : cfg.memory_bytes;
  impl_->mem = std::make_unique<FaDmaMemModel>(mem_bytes);
  impl_->inited = true;
  return true;
}

void FaVeriTop::shutdown() {
  if (!impl_->inited) {
    return;
  }
  impl_->mem.reset();
  impl_->inited = false;
}

bool FaVeriTop::axil_write(uint32_t addr, uint32_t data) {
  if (!impl_->inited) {
    return false;
  }

  switch (addr) {
    case REG_CTRL:
      if (data & 0x1u) {
        impl_->on_enqueue_pulse();
      }
      break;
    case REG_STATUS:
      if (data & (1u << 1)) {
        impl_->done_sticky = false;
      }
      break;
    case REG_CFG:
      impl_->causal_en = (data & 0x1u) != 0;
      break;
    case REG_Q_BASE_L:
      impl_->q_base = (impl_->q_base & 0xFFFFFFFF00000000ull) | static_cast<uint64_t>(data);
      break;
    case REG_Q_BASE_H:
      impl_->q_base = (impl_->q_base & 0x00000000FFFFFFFFull) | (static_cast<uint64_t>(data) << 32);
      break;
    case REG_K_BASE_L:
      impl_->k_base = (impl_->k_base & 0xFFFFFFFF00000000ull) | static_cast<uint64_t>(data);
      break;
    case REG_K_BASE_H:
      impl_->k_base = (impl_->k_base & 0x00000000FFFFFFFFull) | (static_cast<uint64_t>(data) << 32);
      break;
    case REG_V_BASE_L:
      impl_->v_base = (impl_->v_base & 0xFFFFFFFF00000000ull) | static_cast<uint64_t>(data);
      break;
    case REG_V_BASE_H:
      impl_->v_base = (impl_->v_base & 0x00000000FFFFFFFFull) | (static_cast<uint64_t>(data) << 32);
      break;
    case REG_O_BASE_L:
      impl_->o_base = (impl_->o_base & 0xFFFFFFFF00000000ull) | static_cast<uint64_t>(data);
      break;
    case REG_O_BASE_H:
      impl_->o_base = (impl_->o_base & 0x00000000FFFFFFFFull) | (static_cast<uint64_t>(data) << 32);
      break;
    case REG_STRIDE_BYTES:
      impl_->stride_bytes = data;
      break;
    case REG_NEG_LARGE:
      impl_->neg_large_q8_8 = static_cast<int16_t>(data & 0xFFFFu);
      break;
    case REG_SCALE:
      impl_->scale_q8_8 = static_cast<int16_t>(data & 0xFFFFu);
      break;
    case REG_QUEUE_CMD:
      if (data & QUEUE_CMD_ENQUEUE) {
        impl_->on_enqueue_pulse();
      }
      if (data & QUEUE_CMD_CLR_OVERFLOW) {
        impl_->queue_overflow_sticky = false;
      }
      if (data & QUEUE_CMD_CLR_UNDERFLOW) {
        impl_->queue_underflow_sticky = false;
      }
      if (data & QUEUE_CMD_CLR_DESC_ERROR) {
        impl_->queue_desc_error_sticky = false;
      }
      if (data & QUEUE_CMD_FLUSH) {
        impl_->on_flush_pulse();
      }
      break;
    default:
      break;
  }

  return true;
}

bool FaVeriTop::axil_read(uint32_t addr, uint32_t &data) {
  if (!impl_->inited) {
    return false;
  }

  switch (addr) {
    case REG_STATUS:
      data = ((impl_->run_busy() ? 1u : 0u) << 0) |
             ((impl_->done_sticky ? 1u : 0u) << 1);
      return true;
    case REG_CYCLES:
      data = impl_->cycles_reg;
      return true;
    case REG_QUEUE_STATUS:
      data = impl_->build_queue_status();
      return true;
    case REG_QUEUE_CAPACITY:
      data = (8u << 8) | (impl_->fifo_depth & 0xFFu);
      return true;
    case REG_TASK_ACCEPT_COUNT:
      data = impl_->task_accept_count;
      return true;
    case REG_TASK_DONE_COUNT:
      data = impl_->task_done_count;
      return true;
    case REG_TASK_ERROR_COUNT:
      data = impl_->task_error_count;
      return true;
    case REG_LAST_ERROR:
      data = impl_->last_error;
      return true;
    case REG_PERF_RUN_COUNT:
      data = impl_->run_count;
      return true;
    case REG_PERF_BUSY_CYCLES:
      data = impl_->busy_cycles;
      return true;
    case REG_PERF_DMA_RD_CMD_COUNT:
    case REG_PERF_DMA_RD_BEAT_COUNT:
    case REG_PERF_DMA_WR_CMD_COUNT:
    case REG_PERF_DMA_WR_BEAT_COUNT:
    case REG_PERF_COMP_LAUNCH_COUNT:
      data = 0;
      return true;
    default:
      data = 0;
      return true;
  }
}

void FaVeriTop::tick(uint32_t cycles) {
  if (!impl_->inited) {
    return;
  }

  for (uint32_t i = 0; i < cycles; ++i) {
    if (impl_->run_busy()) {
      impl_->busy_cycles++;
    }
    if (impl_->busy_exec) {
      impl_->active_task_cycles++;
      if (impl_->active_task_cycles >= impl_->active_task_target) {
        impl_->busy_exec = false;
        impl_->cycles_reg = impl_->active_task_cycles;
        impl_->active_task_cycles = 0;
        impl_->task_done_count++;
        impl_->maybe_launch_active_task();
        if (!impl_->run_busy()) {
          impl_->done_sticky = true;
        }
      }
    }
  }
}

bool FaVeriTop::mem_write(uint64_t addr, const void *src, uint32_t bytes) {
  if (!impl_->inited || !impl_->mem) {
    return false;
  }
  return impl_->mem->write(addr, src, bytes);
}

bool FaVeriTop::mem_read(uint64_t addr, void *dst, uint32_t bytes) const {
  if (!impl_->inited || !impl_->mem) {
    return false;
  }
  return impl_->mem->read(addr, dst, bytes);
}

} // namespace fa::dpi
