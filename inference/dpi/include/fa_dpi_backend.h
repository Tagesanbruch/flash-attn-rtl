#ifndef FA_DPI_BACKEND_H
#define FA_DPI_BACKEND_H

#include "fa_dpi_types.h"

#ifdef __cplusplus
extern "C" {
#endif

fa_dpi_status_t fa_dpi_init(const fa_dpi_init_cfg_t *cfg);
void fa_dpi_shutdown(void);

fa_dpi_status_t fa_dpi_submit_task(const fa_task_desc_t *desc);
fa_dpi_status_t fa_dpi_get_queue_status(fa_queue_status_t *status);
fa_dpi_status_t fa_dpi_wait_idle(uint32_t timeout_cycles);
fa_dpi_status_t fa_dpi_read_perf(fa_perf_snapshot_t *snapshot);

fa_dpi_status_t fa_dpi_mem_write(uint64_t addr, const void *src, uint32_t bytes);
fa_dpi_status_t fa_dpi_mem_read(uint64_t addr, void *dst, uint32_t bytes);

#ifdef __cplusplus
}
#endif

#endif
