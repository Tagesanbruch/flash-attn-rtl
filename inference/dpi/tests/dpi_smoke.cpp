#include <array>
#include <cstdint>
#include <iostream>

#include "fa_dpi_backend.h"

int main() {
  fa_dpi_init_cfg_t cfg{};
  cfg.memory_bytes = 8 * 1024 * 1024;
  cfg.fifo_depth = 4;
  cfg.wait_poll_interval_cycles = 64;
  cfg.verbose = false;
  cfg.enable_verilator = false;

  if (fa_dpi_init(&cfg) != FA_DPI_OK) {
    std::cerr << "fa_dpi_init failed\n";
    return 1;
  }

  std::array<int16_t, 64> data{};
  for (size_t i = 0; i < data.size(); ++i) {
    data[i] = static_cast<int16_t>(i);
  }

  if (fa_dpi_mem_write(0x0000, data.data(), static_cast<uint32_t>(data.size() * sizeof(int16_t))) != FA_DPI_OK) {
    std::cerr << "mem_write failed\n";
    fa_dpi_shutdown();
    return 2;
  }

  fa_task_desc_t desc{};
  desc.q_base = 0x0000;
  desc.k_base = 0x1000;
  desc.v_base = 0x2000;
  desc.o_base = 0x3000;
  desc.stride_bytes = 128;
  desc.neg_large_q8_8 = static_cast<int16_t>(0x8000);
  desc.scale_q8_8 = 32;
  desc.causal_en = true;
  desc.op_type = FA_OP_ATTN;

  fa_dpi_status_t submit_st = fa_dpi_submit_task(&desc);
  if (submit_st != FA_DPI_OK) {
    std::cerr << "submit_task failed, status=" << static_cast<int>(submit_st) << "\n";
    fa_queue_status_t dbg_q{};
    fa_perf_snapshot_t dbg_perf{};
    if (fa_dpi_get_queue_status(&dbg_q) == FA_DPI_OK) {
      std::cerr << "queue: empty=" << static_cast<int>(dbg_q.queue_empty)
                << " full=" << static_cast<int>(dbg_q.queue_full)
                << " ready=" << static_cast<int>(dbg_q.queue_ready)
                << " busy=" << static_cast<int>(dbg_q.queue_busy_exec)
                << " count=" << static_cast<int>(dbg_q.queue_count)
                << " free=" << static_cast<int>(dbg_q.queue_free_slots)
                << " ovf=" << static_cast<int>(dbg_q.queue_overflow_sticky)
                << " udf=" << static_cast<int>(dbg_q.queue_underflow_sticky)
                << " desc=" << static_cast<int>(dbg_q.queue_desc_error_sticky)
                << " last_err=" << dbg_q.last_error << "\n";
    }
    if (fa_dpi_read_perf(&dbg_perf) == FA_DPI_OK) {
      std::cerr << "perf: cycles=" << dbg_perf.cycles
                << " accept=" << dbg_perf.task_accept_count
                << " done=" << dbg_perf.task_done_count
                << " err=" << dbg_perf.task_error_count
                << " run=" << dbg_perf.run_count << "\n";
    }
    fa_dpi_shutdown();
    return 3;
  }

  if (fa_dpi_wait_idle(20000000) != FA_DPI_OK) {
    std::cerr << "wait_idle failed\n";
    fa_queue_status_t dbg_q{};
    fa_perf_snapshot_t dbg_perf{};
    if (fa_dpi_get_queue_status(&dbg_q) == FA_DPI_OK) {
      std::cerr << "queue: empty=" << static_cast<int>(dbg_q.queue_empty)
                << " full=" << static_cast<int>(dbg_q.queue_full)
                << " ready=" << static_cast<int>(dbg_q.queue_ready)
                << " busy=" << static_cast<int>(dbg_q.queue_busy_exec)
                << " count=" << static_cast<int>(dbg_q.queue_count)
                << " free=" << static_cast<int>(dbg_q.queue_free_slots)
                << " ovf=" << static_cast<int>(dbg_q.queue_overflow_sticky)
                << " udf=" << static_cast<int>(dbg_q.queue_underflow_sticky)
                << " desc=" << static_cast<int>(dbg_q.queue_desc_error_sticky)
                << " last_err=" << dbg_q.last_error << "\n";
    }
    if (fa_dpi_read_perf(&dbg_perf) == FA_DPI_OK) {
      std::cerr << "perf: cycles=" << dbg_perf.cycles
                << " run=" << dbg_perf.run_count
                << " busy=" << dbg_perf.busy_cycles
                << " rd_cmd=" << dbg_perf.dma_rd_cmd_count
                << " rd_beat=" << dbg_perf.dma_rd_beat_count
                << " wr_cmd=" << dbg_perf.dma_wr_cmd_count
                << " wr_beat=" << dbg_perf.dma_wr_beat_count
                << " comp=" << dbg_perf.comp_launch_count
                << " accept=" << dbg_perf.task_accept_count
                << " done=" << dbg_perf.task_done_count
                << " err=" << dbg_perf.task_error_count
                << " last_err=" << dbg_perf.last_error << "\n";
    }
    fa_dpi_shutdown();
    return 4;
  }

  fa_perf_snapshot_t perf{};
  if (fa_dpi_read_perf(&perf) != FA_DPI_OK) {
    std::cerr << "read_perf failed\n";
    fa_dpi_shutdown();
    return 5;
  }

  if (perf.task_accept_count < 1 || perf.task_done_count < 1) {
    std::cerr << "unexpected perf counters\n";
    fa_dpi_shutdown();
    return 6;
  }

  fa_queue_status_t qst{};
  if (fa_dpi_get_queue_status(&qst) != FA_DPI_OK || !qst.queue_empty) {
    std::cerr << "queue not drained\n";
    fa_dpi_shutdown();
    return 7;
  }

  fa_dpi_shutdown();
  std::cout << "dpi_smoke passed\n";
  return 0;
}
