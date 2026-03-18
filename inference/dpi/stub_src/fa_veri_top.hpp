#pragma once

#include <cstdint>
#include <memory>

#include "fa_dpi_types.h"
#include "fa_dma_mem_model.hpp"

namespace fa::dpi {

class FaVeriTop {
 public:
  FaVeriTop();
  ~FaVeriTop();

  bool init(const fa_dpi_init_cfg_t &cfg);
  void shutdown();

  bool axil_write(uint32_t addr, uint32_t data);
  bool axil_read(uint32_t addr, uint32_t &data);

  void tick(uint32_t cycles);

  bool mem_write(uint64_t addr, const void *src, uint32_t bytes);
  bool mem_read(uint64_t addr, void *dst, uint32_t bytes) const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace fa::dpi
