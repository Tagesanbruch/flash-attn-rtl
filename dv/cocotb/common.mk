include ../../cfg/sim.mk
include tb/filelist.mk

export PYTHONPATH := $(abspath tests):$(PYTHONPATH)
MODULE ?= fa_mul_sat_q8_8
SELECTED_MODULE := $(MODULE)
PYTHON_BIN ?= $(ROOT_DIR)/.venv/bin/python
COCOTB_CONFIG ?= $(ROOT_DIR)/.venv/bin/cocotb-config

ifeq ($(wildcard $(PYTHON_BIN)),)
PYTHON_BIN := python3
endif

ifeq ($(wildcard $(COCOTB_CONFIG)),)
COCOTB_CONFIG := $(shell command -v cocotb-config)
endif

ifeq ($(SELECTED_MODULE),fa_mul_sat_q8_8)
TOPLEVEL := fa_mul_sat_q8_8
MODULE_PY := test_fa_mul_sat_q8_8
VERILOG_SOURCES := $(RTL_COMMON_DIR)/fa_mul_sat_q8_8.sv
endif

ifeq ($(SELECTED_MODULE),fa_exp_pwl_8seg_q1_15)
TOPLEVEL := fa_exp_pwl_8seg_q1_15
MODULE_PY := test_fa_exp_pwl_8seg_q1_15
VERILOG_SOURCES := $(RTL_SOFTMAX_DIR)/fa_exp_pwl_8seg_q1_15.sv
endif

ifeq ($(SELECTED_MODULE),fa_recip_nr_q16_16)
TOPLEVEL := fa_recip_nr_q16_16
MODULE_PY := test_fa_recip_nr_q16_16
VERILOG_SOURCES := $(RTL_SOFTMAX_DIR)/fa_recip_nr_q16_16.sv
endif

ifeq ($(SELECTED_MODULE),fa_online_softmax_ctx)
TOPLEVEL := fa_online_softmax_ctx
MODULE_PY := test_fa_online_softmax_ctx
VERILOG_SOURCES := $(RTL_CORE_DIR)/fa_online_softmax_ctx.sv
endif

ifeq ($(SELECTED_MODULE),fa_attention_ip_top)
TOPLEVEL := fa_attention_ip_top
MODULE_PY := test_fa_attention_ip_top_regs
VERILOG_SOURCES := \
	$(RTL_COMMON_DIR)/fa_fixed_point_pkg.sv \
	$(RTL_COMMON_DIR)/fa_mul_sat_q8_8.sv \
	$(RTL_SOFTMAX_DIR)/fa_exp_pwl_8seg_q1_15.sv \
	$(RTL_SOFTMAX_DIR)/fa_recip_nr_q16_16.sv \
	$(RTL_CORE_DIR)/fa_qk_dotprod_slice.sv \
	$(RTL_CORE_DIR)/fa_online_softmax_ctx.sv \
	$(RTL_CORE_DIR)/fa_o_normalize_block.sv \
	$(RTL_BUS_DIR)/fa_axi_lite_regs.sv \
	$(RTL_BUS_DIR)/fa_dma_reader.sv \
	$(RTL_BUS_DIR)/fa_dma_writer.sv \
	$(RTL_CORE_DIR)/fa_attention_core.sv \
	$(RTL_TOP_DIR)/fa_perf_counters.sv \
	$(RTL_TOP_DIR)/fa_attention_ip_top.sv
endif

ifeq ($(SELECTED_MODULE),fa_dma_reader)
TOPLEVEL := fa_dma_reader
MODULE_PY := test_fa_dma_reader
VERILOG_SOURCES := $(RTL_BUS_DIR)/fa_dma_reader.sv
endif

ifeq ($(SELECTED_MODULE),fa_dma_writer)
TOPLEVEL := fa_dma_writer
MODULE_PY := test_fa_dma_writer
VERILOG_SOURCES := $(RTL_BUS_DIR)/fa_dma_writer.sv
endif

ifeq ($(SELECTED_MODULE),fa_attention_core)
TOPLEVEL := fa_attention_core
MODULE_PY := test_fa_attention_core
VERILOG_SOURCES := \
	$(RTL_COMMON_DIR)/fa_mul_sat_q8_8.sv \
	$(RTL_SOFTMAX_DIR)/fa_exp_pwl_8seg_q1_15.sv \
	$(RTL_SOFTMAX_DIR)/fa_recip_nr_q16_16.sv \
	$(RTL_CORE_DIR)/fa_qk_dotprod_slice.sv \
	$(RTL_CORE_DIR)/fa_online_softmax_ctx.sv \
	$(RTL_CORE_DIR)/fa_o_normalize_block.sv \
	$(RTL_CORE_DIR)/fa_attention_core.sv
# Small parameters for fast testing: S=32, D=8, TQ=8, TK=8
COMPILE_ARGS += -GSEQ_LEN=32 -GD=8 -GTQ=8 -GTK=8
export PARAM_SEQ_LEN := 32
export PARAM_D := 8
export PARAM_TQ := 8
export PARAM_TK := 8
endif

# Full-parameter test matching contest spec: S=256, D=64, TQ=32, TK=64 (default RTL params)
ifeq ($(SELECTED_MODULE),fa_attention_core_full)
TOPLEVEL := fa_attention_core
MODULE_PY := test_fa_attention_core
VERILOG_SOURCES := \
	$(RTL_COMMON_DIR)/fa_mul_sat_q8_8.sv \
	$(RTL_SOFTMAX_DIR)/fa_exp_pwl_8seg_q1_15.sv \
	$(RTL_SOFTMAX_DIR)/fa_recip_nr_q16_16.sv \
	$(RTL_CORE_DIR)/fa_qk_dotprod_slice.sv \
	$(RTL_CORE_DIR)/fa_online_softmax_ctx.sv \
	$(RTL_CORE_DIR)/fa_o_normalize_block.sv \
	$(RTL_CORE_DIR)/fa_attention_core.sv
# No -G overrides: uses RTL defaults SEQ_LEN=256, D=64, TQ=32, TK=64
# No PARAM_* exports: Python defaults match RTL defaults
endif

ifeq ($(strip $(TOPLEVEL)),)
$(error Unsupported MODULE=$(SELECTED_MODULE). Run: make -C dv/cocotb list)
endif

SIM_BUILD ?= sim_build/$(MODULE)
COCOTB_RESULTS_FILE ?= $(SIM_BUILD)/results.xml

EXTRA_ARGS += -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL

# waveform generation control: set WAVES=1 to enable, and optionally
# pick format via WAVE_FMT (fst or vcd). default is fst for compact files.
WAVES ?= 0
WAVE_FMT ?= fst

ifeq ($(WAVES),1)
ifeq ($(WAVE_FMT),vcd)
EXTRA_ARGS += --trace
else
EXTRA_ARGS += --trace --trace-fst
endif
endif

export TOPLEVEL MODULE
export VERILOG_SOURCES
export TOPLEVEL_LANG
export SIM
export SIM_BUILD
export COCOTB_RESULTS_FILE
export EXTRA_ARGS
export COMPILE_ARGS
export PYTHON := $(PYTHON_BIN)
export MODULE := $(MODULE_PY)

COCOTB_MAKEFILE := $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim
