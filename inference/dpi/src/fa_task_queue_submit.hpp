#pragma once

#include <cstdint>

#include "fa_axil_driver.hpp"
#include "fa_dpi_types.h"

namespace fa::dpi {

fa_dpi_status_t submit_task_via_queue(FaAxilDriver &driver, const fa_task_desc_t &desc,
                                      uint32_t poll_timeout_cycles, uint32_t poll_step_cycles,
                                      uint32_t *accepted_count_after = nullptr);

fa_dpi_status_t read_queue_status(FaAxilDriver &driver, fa_queue_status_t &status);

} // namespace fa::dpi
