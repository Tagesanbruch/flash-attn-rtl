#include "fa_axil_driver.hpp"

namespace fa::dpi {

bool FaAxilDriver::write32(uint32_t addr, uint32_t value) {
  return top_.axil_write(addr, value);
}

bool FaAxilDriver::read32(uint32_t addr, uint32_t &value) {
  return top_.axil_read(addr, value);
}

} // namespace fa::dpi
