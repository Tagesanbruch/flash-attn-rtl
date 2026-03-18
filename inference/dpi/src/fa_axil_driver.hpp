#pragma once

#include <cstdint>

#include "fa_veri_top.hpp"

namespace fa::dpi {

class FaAxilDriver {
 public:
  explicit FaAxilDriver(FaVeriTop &top) : top_(top) {}

  bool write32(uint32_t addr, uint32_t value);
  bool read32(uint32_t addr, uint32_t &value);

 private:
  FaVeriTop &top_;
};

} // namespace fa::dpi
