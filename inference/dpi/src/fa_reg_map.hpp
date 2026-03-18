#pragma once

#include <cstdint>

namespace fa::dpi {

constexpr uint32_t REG_CTRL = 0x00;
constexpr uint32_t REG_STATUS = 0x04;
constexpr uint32_t REG_CFG = 0x08;
constexpr uint32_t REG_Q_BASE_L = 0x14;
constexpr uint32_t REG_Q_BASE_H = 0x18;
constexpr uint32_t REG_K_BASE_L = 0x1C;
constexpr uint32_t REG_K_BASE_H = 0x20;
constexpr uint32_t REG_V_BASE_L = 0x24;
constexpr uint32_t REG_V_BASE_H = 0x28;
constexpr uint32_t REG_O_BASE_L = 0x2C;
constexpr uint32_t REG_O_BASE_H = 0x30;
constexpr uint32_t REG_STRIDE_BYTES = 0x34;
constexpr uint32_t REG_NEG_LARGE = 0x38;
constexpr uint32_t REG_SCALE = 0x3C;
constexpr uint32_t REG_CYCLES = 0x40;

constexpr uint32_t REG_QUEUE_CMD = 0x44;
constexpr uint32_t REG_QUEUE_STATUS = 0x48;
constexpr uint32_t REG_QUEUE_CAPACITY = 0x4C;
constexpr uint32_t REG_TASK_ACCEPT_COUNT = 0x50;
constexpr uint32_t REG_TASK_DONE_COUNT = 0x54;
constexpr uint32_t REG_TASK_ERROR_COUNT = 0x58;
constexpr uint32_t REG_LAST_ERROR = 0x5C;

constexpr uint32_t REG_PERF_RUN_COUNT = 0x80;
constexpr uint32_t REG_PERF_BUSY_CYCLES = 0x84;
constexpr uint32_t REG_PERF_DMA_RD_CMD_COUNT = 0x88;
constexpr uint32_t REG_PERF_DMA_RD_BEAT_COUNT = 0x8C;
constexpr uint32_t REG_PERF_DMA_WR_CMD_COUNT = 0x90;
constexpr uint32_t REG_PERF_DMA_WR_BEAT_COUNT = 0x94;
constexpr uint32_t REG_PERF_COMP_LAUNCH_COUNT = 0x98;

constexpr uint32_t QUEUE_CMD_ENQUEUE = 1u << 0;
constexpr uint32_t QUEUE_CMD_CLR_OVERFLOW = 1u << 1;
constexpr uint32_t QUEUE_CMD_CLR_UNDERFLOW = 1u << 2;
constexpr uint32_t QUEUE_CMD_CLR_DESC_ERROR = 1u << 3;
constexpr uint32_t QUEUE_CMD_FLUSH = 1u << 4;

} // namespace fa::dpi
