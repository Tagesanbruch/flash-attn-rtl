ROOT_DIR := $(abspath ../../..)
DV_UVM_DIR := $(ROOT_DIR)/dv/uvm
UVM_HOME ?= $(DV_UVM_DIR)/lib/uvm-verilator
VERILATOR ?= verilator
BUILD_ROOT ?= $(DV_UVM_DIR)/build
BUILD_DIR ?= $(BUILD_ROOT)/$(TEST)
TOP ?= fa_attention_ip_top_tb
TEST ?= fa_top_smoke_test
VERBOSITY ?= UVM_MEDIUM
WAVES ?= 0
BUILD_JOBS ?= 8
EXTRA_DEFINES ?=

RTL_COMMON_DIR := $(ROOT_DIR)/rtl/common
RTL_SOFTMAX_DIR := $(ROOT_DIR)/rtl/softmax
RTL_CORE_DIR := $(ROOT_DIR)/rtl/core
RTL_BUS_DIR := $(ROOT_DIR)/rtl/bus
RTL_TOP_DIR := $(ROOT_DIR)/rtl/top

RTL_SOURCES := \
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

VERILATOR_FLAGS := --binary --vpi --sv --timing --assert \
	--build-jobs $(BUILD_JOBS) --output-groups $(BUILD_JOBS) \
	--x-assign 0 --x-initial 0 \
	$(EXTRA_DEFINES) \
	--top-module $(TOP) \
	-Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
	-Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-CASEINCOMPLETE

ifeq ($(WAVES),1)
VERILATOR_FLAGS += --trace-fst
endif

.PHONY: sim_verilator smoke perf clean

sim_verilator:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) -Mdir $(BUILD_DIR) \
		-I$(UVM_HOME)/src -I$(DV_UVM_DIR) \
		$(UVM_HOME)/src/uvm_pkg.sv \
		$(UVM_HOME)/src/dpi/uvm_dpi.cc \
		-f $(DV_UVM_DIR)/tb/sv/uvm_filelist.f \
		$(RTL_SOURCES)
	$(BUILD_DIR)/V$(TOP) +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERBOSITY)

smoke:
	$(MAKE) sim_verilator TEST=fa_top_smoke_test

perf:
	$(MAKE) sim_verilator TEST=fa_perf_test

clean:
	rm -rf $(BUILD_ROOT)