#include "fa_dma_mem_model.hpp"

#include <cstring>

namespace fa::dpi {

FaDmaMemModel::FaDmaMemModel(uint32_t size_bytes) : memory_(size_bytes, 0) {}

bool FaDmaMemModel::write(uint64_t addr, const void *src, uint32_t bytes) {
  if (src == nullptr) {
    return false;
  }
  if (addr + bytes > memory_.size()) {
    return false;
  }
  std::memcpy(memory_.data() + addr, src, bytes);
  return true;
}

bool FaDmaMemModel::read(uint64_t addr, void *dst, uint32_t bytes) const {
  if (dst == nullptr) {
    return false;
  }
  if (addr + bytes > memory_.size()) {
    return false;
  }
  std::memcpy(dst, memory_.data() + addr, bytes);
  return true;
}

uint32_t FaDmaMemModel::size_bytes() const { return static_cast<uint32_t>(memory_.size()); }

} // namespace fa::dpi
