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

ifeq ($(SELECTED_MODULE),fa_online_softmax_update)
TOPLEVEL := fa_online_softmax_update
MODULE_PY := test_fa_online_softmax_update
VERILOG_SOURCES := \
	$(RTL_SOFTMAX_DIR)/fa_exp_pwl_8seg_q1_15.sv \
	$(RTL_SOFTMAX_DIR)/fa_online_softmax_update.sv
endif

ifeq ($(strip $(TOPLEVEL)),)
$(error Unsupported MODULE=$(SELECTED_MODULE), use one of: fa_mul_sat_q8_8 fa_exp_pwl_8seg_q1_15 fa_recip_nr_q16_16 fa_online_softmax_update)
endif

SIM_BUILD ?= sim_build/$(MODULE)
COCOTB_RESULTS_FILE ?= $(SIM_BUILD)/results.xml

ifeq ($(WAVES),1)
EXTRA_ARGS += --trace --trace-fst
endif

export TOPLEVEL MODULE
export VERILOG_SOURCES
export TOPLEVEL_LANG
export SIM
export SIM_BUILD
export COCOTB_RESULTS_FILE
export EXTRA_ARGS
export PYTHON := $(PYTHON_BIN)
export MODULE := $(MODULE_PY)

COCOTB_MAKEFILE := $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim
