# Per-module RTL dependency list for yosys-sta
# Usage:
#   include cfg/sta_modules.mk
#   $(call sta_get_rtl_files,<module>)
#   $(call sta_is_clocked,<module>)

STA_MODULES := \
	fa_mul_sat_q8_8 \
	fa_exp_pwl_8seg_q1_15 \
	fa_recip_nr_q16_16 \
	fa_axi_lite_regs \
	fa_attention_ip_top

STA_CLOCKED_MODULES := \
	fa_recip_nr_q16_16 \
	fa_axi_lite_regs \
	fa_attention_ip_top

STA_RTL_fa_mul_sat_q8_8 := rtl/common/fa_mul_sat_q8_8.sv
STA_RTL_fa_exp_pwl_8seg_q1_15 := rtl/softmax/fa_exp_pwl_8seg_q1_15.sv
STA_RTL_fa_recip_nr_q16_16 := rtl/softmax/fa_recip_nr_q16_16.sv
STA_RTL_fa_axi_lite_regs := rtl/bus/fa_axi_lite_regs.sv
STA_RTL_fa_attention_ip_top := \
	rtl/common/fa_mul_sat_q8_8.sv \
	rtl/softmax/fa_exp_pwl_8seg_q1_15.sv \
	rtl/softmax/fa_recip_nr_q16_16.sv \
	rtl/bus/fa_axi_lite_regs.sv \
	rtl/bus/fa_dma_reader.sv \
	rtl/bus/fa_dma_writer.sv \
	rtl/core/fa_attention_core.sv \
	rtl/top/fa_attention_ip_top.sv

sta_get_rtl_files = $(STA_RTL_$(1))
sta_is_clocked = $(filter $(1),$(STA_CLOCKED_MODULES))
