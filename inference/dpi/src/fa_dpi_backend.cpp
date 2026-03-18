#include "fa_dpi_backend.h"

#include <mutex>

#include "fa_axil_driver.hpp"
#include "fa_reg_map.hpp"
#include "fa_task_queue_submit.hpp"
#include "fa_veri_top.hpp"

namespace fa::dpi {

namespace {

class BackendContext {
 public:
  fa_dpi_status_t init(const fa_dpi_init_cfg_t *cfg) {
    if (cfg == nullptr) {
      return FA_DPI_E_BAD_ARG;
    }
    if (initialized_) {
      return FA_DPI_OK;
    }
    if (!top_.init(*cfg)) {
      return FA_DPI_E_INTERNAL;
    }
    top_.tick(64);
    cfg_ = *cfg;
    initialized_ = true;
    return FA_DPI_OK;
  }

  void shutdown() {
    if (!initialized_) {
      return;
    }
    top_.shutdown();
    initialized_ = false;
  }

  bool initialized() const { return initialized_; }

  fa_dpi_status_t submit_task(const fa_task_desc_t *desc) {
    if (desc == nullptr) {
      return FA_DPI_E_BAD_ARG;
    }
    if (!initialized_) {
      return FA_DPI_E_NOT_INIT;
    }
    FaAxilDriver driver(top_);
    const uint32_t timeout_cycles = 50000;
    const uint32_t step_cycles = cfg_.wait_poll_interval_cycles == 0 ? 64 : cfg_.wait_poll_interval_cycles;
    return submit_task_via_queue(driver, *desc, timeout_cycles, step_cycles, nullptr);
  }

  fa_dpi_status_t get_queue_status(fa_queue_status_t *status) {
    if (status == nullptr) {
      return FA_DPI_E_BAD_ARG;
    }
    if (!initialized_) {
      return FA_DPI_E_NOT_INIT;
    }
    FaAxilDriver driver(top_);
    return read_queue_status(driver, *status);
  }

  fa_dpi_status_t wait_idle(uint32_t timeout_cycles) {
    if (!initialized_) {
      return FA_DPI_E_NOT_INIT;
    }
    FaAxilDriver driver(top_);
    uint32_t elapsed = 0;
    const uint32_t step = cfg_.wait_poll_interval_cycles == 0 ? 64 : cfg_.wait_poll_interval_cycles;
    while (elapsed < timeout_cycles) {
      uint32_t status = 0;
      if (!driver.read32(REG_STATUS, status)) {
        return FA_DPI_E_INTERNAL;
      }
      if (((status >> 0) & 0x1u) == 0) {
        return FA_DPI_OK;
      }
      top_.tick(step);
      elapsed += step;
    }
    return FA_DPI_E_TIMEOUT;
  }

  fa_dpi_status_t read_perf(fa_perf_snapshot_t *snapshot) {
    if (snapshot == nullptr) {
      return FA_DPI_E_BAD_ARG;
    }
    if (!initialized_) {
      return FA_DPI_E_NOT_INIT;
    }

    FaAxilDriver driver(top_);
    if (!driver.read32(REG_CYCLES, snapshot->cycles)) return FA_DPI_E_INTERNAL;
    if (!driver.read32(REG_PERF_RUN_COUNT, snapshot->run_count)) return FA_DPI_E_INTERNAL;
    if (!driver.read32(REG_PERF_BUSY_CYCLES, snapshot->busy_cycles)) return FA_DPI_E_INTERNAL;
    if (!driver.read32(REG_PERF_DMA_RD_CMD_COUNT, snapshot->dma_rd_cmd_count)) return FA_DPI_E_INTERNAL;
    if (!driver.read32(REG_PERF_DMA_RD_BEAT_COUNT, snapshot->dma_rd_beat_count)) return FA_DPI_E_INTERNAL;
    if (!driver.read32(REG_PERF_DMA_WR_CMD_COUNT, snapshot->dma_wr_cmd_count)) return FA_DPI_E_INTERNAL;
    if (!driver.read32(REG_PERF_DMA_WR_BEAT_COUNT, snapshot->dma_wr_beat_count)) return FA_DPI_E_INTERNAL;
    if (!driver.read32(REG_PERF_COMP_LAUNCH_COUNT, snapshot->comp_launch_count)) return FA_DPI_E_INTERNAL;
    if (!driver.read32(REG_TASK_ACCEPT_COUNT, snapshot->task_accept_count)) return FA_DPI_E_INTERNAL;
    if (!driver.read32(REG_TASK_DONE_COUNT, snapshot->task_done_count)) return FA_DPI_E_INTERNAL;
    if (!driver.read32(REG_TASK_ERROR_COUNT, snapshot->task_error_count)) return FA_DPI_E_INTERNAL;
    if (!driver.read32(REG_LAST_ERROR, snapshot->last_error)) return FA_DPI_E_INTERNAL;
    return FA_DPI_OK;
  }

  fa_dpi_status_t mem_write(uint64_t addr, const void *src, uint32_t bytes) {
    if (!initialized_) {
      return FA_DPI_E_NOT_INIT;
    }
    if (!top_.mem_write(addr, src, bytes)) {
      return FA_DPI_E_BAD_ARG;
    }
    return FA_DPI_OK;
  }

  fa_dpi_status_t mem_read(uint64_t addr, void *dst, uint32_t bytes) {
    if (!initialized_) {
      return FA_DPI_E_NOT_INIT;
    }
    if (!top_.mem_read(addr, dst, bytes)) {
      return FA_DPI_E_BAD_ARG;
    }
    return FA_DPI_OK;
  }

 private:
  bool initialized_ = false;
  fa_dpi_init_cfg_t cfg_{};
  FaVeriTop top_;
};

BackendContext &ctx() {
  static BackendContext context;
  return context;
}

std::mutex &ctx_mutex() {
  static std::mutex mutex;
  return mutex;
}

} // namespace

} // namespace fa::dpi

extern "C" {

fa_dpi_status_t fa_dpi_init(const fa_dpi_init_cfg_t *cfg) {
  std::lock_guard<std::mutex> lock(fa::dpi::ctx_mutex());
  return fa::dpi::ctx().init(cfg);
}

void fa_dpi_shutdown(void) {
  std::lock_guard<std::mutex> lock(fa::dpi::ctx_mutex());
  fa::dpi::ctx().shutdown();
}

fa_dpi_status_t fa_dpi_submit_task(const fa_task_desc_t *desc) {
  std::lock_guard<std::mutex> lock(fa::dpi::ctx_mutex());
  return fa::dpi::ctx().submit_task(desc);
}

fa_dpi_status_t fa_dpi_get_queue_status(fa_queue_status_t *status) {
  std::lock_guard<std::mutex> lock(fa::dpi::ctx_mutex());
  return fa::dpi::ctx().get_queue_status(status);
}

fa_dpi_status_t fa_dpi_wait_idle(uint32_t timeout_cycles) {
  std::lock_guard<std::mutex> lock(fa::dpi::ctx_mutex());
  return fa::dpi::ctx().wait_idle(timeout_cycles);
}

fa_dpi_status_t fa_dpi_read_perf(fa_perf_snapshot_t *snapshot) {
  std::lock_guard<std::mutex> lock(fa::dpi::ctx_mutex());
  return fa::dpi::ctx().read_perf(snapshot);
}

fa_dpi_status_t fa_dpi_mem_write(uint64_t addr, const void *src, uint32_t bytes) {
  std::lock_guard<std::mutex> lock(fa::dpi::ctx_mutex());
  return fa::dpi::ctx().mem_write(addr, src, bytes);
}

fa_dpi_status_t fa_dpi_mem_read(uint64_t addr, void *dst, uint32_t bytes) {
  std::lock_guard<std::mutex> lock(fa::dpi::ctx_mutex());
  return fa::dpi::ctx().mem_read(addr, dst, bytes);
}

}
