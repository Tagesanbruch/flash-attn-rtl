# Per-module RTL dependency list for yosys-sta
# Usage:
#   include cfg/sta_modules.mk
#   $(call sta_get_rtl_files,<module>)
#   $(call sta_is_clocked,<module>)

STA_MODULES := \
	fa_mul_sat_q8_8 \
	fa_exp_pwl_8seg_q1_15 \
	fa_recip_nr_q16_16 \
	fa_dma_reader \
	fa_dma_writer \
	fa_axi_lite_regs \
	fa_qk_dotprod_slice \
	fa_online_softmax_ctx \
	fa_o_normalize_block \
	fa_perf_counters \
	fa_attention_core \
	fa_attention_ip_top

STA_CLOCKED_MODULES := \
	fa_recip_nr_q16_16 \
	fa_dma_reader \
	fa_dma_writer \
	fa_axi_lite_regs \
	fa_qk_dotprod_slice \
	fa_online_softmax_ctx \
	fa_o_normalize_block \
	fa_perf_counters \
	fa_attention_core \
	fa_attention_ip_top

STA_RTL_fa_mul_sat_q8_8 := rtl/common/fa_mul_sat_q8_8.sv
STA_RTL_fa_exp_pwl_8seg_q1_15 := rtl/softmax/fa_exp_pwl_8seg_q1_15.sv
STA_RTL_fa_recip_nr_q16_16 := rtl/softmax/fa_recip_nr_q16_16.sv
STA_RTL_fa_dma_reader := rtl/bus/fa_dma_reader.sv
STA_RTL_fa_dma_writer := rtl/bus/fa_dma_writer.sv
STA_RTL_fa_axi_lite_regs := rtl/bus/fa_axi_lite_regs.sv
STA_RTL_fa_qk_dotprod_slice := rtl/core/fa_qk_dotprod_slice.sv
STA_RTL_fa_online_softmax_ctx := rtl/core/fa_online_softmax_ctx.sv
STA_RTL_fa_o_normalize_block := rtl/core/fa_o_normalize_block.sv
STA_RTL_fa_perf_counters := rtl/top/fa_perf_counters.sv
STA_RTL_fa_attention_core := \
	rtl/common/fa_mul_sat_q8_8.sv \
	rtl/softmax/fa_exp_pwl_8seg_q1_15.sv \
	rtl/softmax/fa_recip_nr_q16_16.sv \
	rtl/core/fa_qk_dotprod_slice.sv \
	rtl/core/fa_online_softmax_ctx.sv \
	rtl/core/fa_o_normalize_block.sv \
	rtl/core/fa_attention_core.sv
STA_RTL_fa_attention_ip_top := \
	rtl/common/fa_mul_sat_q8_8.sv \
	rtl/softmax/fa_exp_pwl_8seg_q1_15.sv \
	rtl/softmax/fa_recip_nr_q16_16.sv \
	rtl/bus/fa_axi_lite_regs.sv \
	rtl/bus/fa_dma_reader.sv \
	rtl/bus/fa_dma_writer.sv \
	rtl/core/fa_qk_dotprod_slice.sv \
	rtl/core/fa_online_softmax_ctx.sv \
	rtl/core/fa_o_normalize_block.sv \
	rtl/core/fa_attention_core.sv \
	rtl/top/fa_perf_counters.sv \
	rtl/top/fa_attention_ip_top.sv

sta_get_rtl_files = $(STA_RTL_$(1))
sta_is_clocked = $(filter $(1),$(STA_CLOCKED_MODULES))
