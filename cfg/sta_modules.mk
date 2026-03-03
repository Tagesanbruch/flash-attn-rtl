# Per-module RTL dependency list for yosys-sta
# Usage:
#   include cfg/sta_modules.mk
#   $(call sta_get_rtl_files,<module>)
#   $(call sta_is_clocked,<module>)

STA_MODULES := \
	fa_clip_signed \
	fa_mul_sat_q8_8 \
	fa_exp_pwl_8seg_q1_15 \
	fa_recip_nr_q16_16 \
	fa_online_softmax_update \
	fa_row_reduction_core \
	fa_axi_lite_regs \
	fa_core_controller \
	fa_attention_ip_top

STA_CLOCKED_MODULES := \
	fa_online_softmax_update \
	fa_row_reduction_core \
	fa_axi_lite_regs \
	fa_core_controller \
	fa_attention_ip_top

STA_RTL_fa_clip_signed := rtl/common/fa_clip_signed.sv
STA_RTL_fa_mul_sat_q8_8 := rtl/common/fa_mul_sat_q8_8.sv
STA_RTL_fa_exp_pwl_8seg_q1_15 := rtl/softmax/fa_exp_pwl_8seg_q1_15.sv
STA_RTL_fa_recip_nr_q16_16 := rtl/softmax/fa_recip_nr_q16_16.sv
STA_RTL_fa_online_softmax_update := \
	rtl/softmax/fa_exp_pwl_8seg_q1_15.sv \
	rtl/softmax/fa_online_softmax_update.sv
STA_RTL_fa_row_reduction_core := \
	rtl/softmax/fa_exp_pwl_8seg_q1_15.sv \
	rtl/softmax/fa_recip_nr_q16_16.sv \
	rtl/softmax/fa_online_softmax_update.sv \
	rtl/core/fa_row_reduction_core.sv
STA_RTL_fa_axi_lite_regs := rtl/bus/fa_axi_lite_regs.sv
STA_RTL_fa_core_controller := rtl/core/fa_core_controller.sv
STA_RTL_fa_attention_ip_top := \
	rtl/bus/fa_axi_lite_regs.sv \
	rtl/core/fa_core_controller.sv \
	rtl/top/fa_attention_ip_top.sv

sta_get_rtl_files = $(STA_RTL_$(1))
sta_is_clocked = $(filter $(1),$(STA_CLOCKED_MODULES))
