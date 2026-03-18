#pragma once

#include <cstdint>
#include <vector>

namespace fa::dpi {

class FaDmaMemModel {
 public:
  explicit FaDmaMemModel(uint32_t size_bytes);

  bool write(uint64_t addr, const void *src, uint32_t bytes);
  bool read(uint64_t addr, void *dst, uint32_t bytes) const;
  uint32_t size_bytes() const;

 private:
  std::vector<uint8_t> memory_;
};

} // namespace fa::dpi
