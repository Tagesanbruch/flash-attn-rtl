.PHONY: setup-py test regress list clean lint compare-torch audit-algo sta-list sta-syn sta-run sta sta-module sta-check-paths

include cfg/sta_modules.mk

MODULE ?= fa_mul_sat_q8_8
LINT_FLAGS := --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC

YOSYS_STA_DIR ?= ../ysyx/yosys-sta
PDK_SRC_DIR ?= ../ysyx/mac/pdk/icsprout55-pdk
PDK_NAME ?= icsprout55

STA_MODULE ?= fa_core_controller
STA_DATE ?= $(shell date +%Y%m%d)
STA_CLK_FREQ_MHZ ?= 500
STA_CLK_PORT ?= clk

STA_RTL_FILES := $(call sta_get_rtl_files,$(STA_MODULE))
STA_OUT_DIR := syn/$(STA_MODULE)_$(STA_DATE)
STA_WORK_DIR := $(YOSYS_STA_DIR)/flashattn_sta/$(STA_MODULE)_$(STA_DATE)
STA_WORK_SDC := $(STA_WORK_DIR)/active_sta.sdc
STA_LOCAL_STA_TCL := syn/scripts/sta_no_power.tcl
STA_WORK_STA_TCL := $(STA_WORK_DIR)/sta_no_power.tcl
STA_SDC_CLOCKED := syn/sdc/default_clocked.sdc
STA_SDC_COMB := syn/sdc/default_comb.sdc
STA_IS_CLOCKED := $(call sta_is_clocked,$(STA_MODULE))
STA_SDC_FILE := $(if $(STA_IS_CLOCKED),$(STA_SDC_CLOCKED),$(STA_SDC_COMB))

setup-py:
	uv venv .venv
	uv pip install --python .venv/bin/python 'cocotb==1.9.2' pytest numpy

test:
	VIRTUAL_ENV=$(PWD)/.venv PATH=$(PWD)/.venv/bin:$$PATH $(MAKE) -C dv/cocotb MODULE=$(MODULE) test

regress:
	VIRTUAL_ENV=$(PWD)/.venv PATH=$(PWD)/.venv/bin:$$PATH $(MAKE) -C dv/cocotb regress

list:
	VIRTUAL_ENV=$(PWD)/.venv PATH=$(PWD)/.venv/bin:$$PATH $(MAKE) -C dv/cocotb list

lint:
	verilator $(LINT_FLAGS) --top-module fa_mul_sat_q8_8 \
		rtl/common/fa_mul_sat_q8_8.sv
	verilator $(LINT_FLAGS) --top-module fa_exp_pwl_8seg_q1_15 \
		rtl/softmax/fa_exp_pwl_8seg_q1_15.sv
	verilator $(LINT_FLAGS) --top-module fa_recip_nr_q16_16 \
		rtl/softmax/fa_recip_nr_q16_16.sv
	verilator $(LINT_FLAGS) --top-module fa_online_softmax_update \
		rtl/softmax/fa_exp_pwl_8seg_q1_15.sv \
		rtl/softmax/fa_online_softmax_update.sv
	verilator $(LINT_FLAGS) --top-module fa_row_reduction_core \
		rtl/softmax/fa_exp_pwl_8seg_q1_15.sv \
		rtl/softmax/fa_recip_nr_q16_16.sv \
		rtl/softmax/fa_online_softmax_update.sv \
		rtl/core/fa_row_reduction_core.sv
	verilator $(LINT_FLAGS) --top-module fa_axi_lite_regs \
		rtl/bus/fa_axi_lite_regs.sv
	verilator $(LINT_FLAGS) --top-module fa_core_controller \
		rtl/core/fa_core_controller.sv
	verilator $(LINT_FLAGS) --top-module fa_dma_reader \
		rtl/bus/fa_dma_reader.sv
	verilator $(LINT_FLAGS) --top-module fa_dma_writer \
		rtl/bus/fa_dma_writer.sv
	verilator $(LINT_FLAGS) --top-module fa_tile_buffer \
		rtl/core/fa_tile_buffer.sv
	verilator $(LINT_FLAGS) --top-module fa_dot_product_d \
		rtl/core/fa_dot_product_d.sv
	verilator $(LINT_FLAGS) --top-module fa_attention_core \
		rtl/common/fa_mul_sat_q8_8.sv \
		rtl/softmax/fa_exp_pwl_8seg_q1_15.sv \
		rtl/softmax/fa_recip_nr_q16_16.sv \
		rtl/core/fa_attention_core.sv
	verilator $(LINT_FLAGS) --top-module fa_attention_ip_top \
		rtl/common/fa_mul_sat_q8_8.sv \
		rtl/softmax/fa_exp_pwl_8seg_q1_15.sv \
		rtl/softmax/fa_recip_nr_q16_16.sv \
		rtl/bus/fa_axi_lite_regs.sv \
		rtl/bus/fa_dma_reader.sv \
		rtl/bus/fa_dma_writer.sv \
		rtl/core/fa_attention_core.sv \
		rtl/top/fa_attention_ip_top.sv

compare-torch:
	VIRTUAL_ENV=$(PWD)/.venv PATH=$(PWD)/.venv/bin:$$PATH python dv/python/torch_compare.py --s 64 --d 64 --causal

audit-algo:
	VIRTUAL_ENV=$(PWD)/.venv PATH=$(PWD)/.venv/bin:$$PATH python dv/python/algorithm_audit.py --seeds 5

sta-list:
	@echo "Supported STA modules:" && \
	for m in $(STA_MODULES); do echo "  - $$m"; done

sta-check-paths:
	@test -d "$(YOSYS_STA_DIR)" || (echo "[ERR] YOSYS_STA_DIR not found: $(YOSYS_STA_DIR)" && exit 1)
	@test -d "$(PDK_SRC_DIR)" || (echo "[ERR] PDK_SRC_DIR not found: $(PDK_SRC_DIR)" && exit 1)
	@test -n "$(STA_RTL_FILES)" || (echo "[ERR] Unsupported STA_MODULE=$(STA_MODULE). Run 'make sta-list'." && exit 1)
	@for f in $(STA_RTL_FILES); do \
		test -f "$$f" || (echo "[ERR] RTL file missing: $$f" && exit 1); \
	done

sta-syn: sta-check-paths
	@mkdir -p syn
	@mkdir -p "$(STA_WORK_DIR)"
	@mkdir -p "$(YOSYS_STA_DIR)/pdk"
	@ln -sfn "$(abspath $(PDK_SRC_DIR))" "$(YOSYS_STA_DIR)/pdk/$(PDK_NAME)"
	$(MAKE) -C $(YOSYS_STA_DIR) syn \
		DESIGN=$(STA_MODULE) \
		RTL_FILES="$(abspath $(STA_RTL_FILES))" \
		PDK=$(PDK_NAME) \
		CLK_FREQ_MHZ=$(STA_CLK_FREQ_MHZ) \
		CLK_PORT_NAME=$(STA_CLK_PORT) \
		O=$(abspath $(STA_WORK_DIR))
	@rm -rf "$(STA_OUT_DIR)"
	@cp -R "$(STA_WORK_DIR)" "$(STA_OUT_DIR)"

sta-run: sta-syn
	@cp "$(STA_SDC_FILE)" "$(STA_WORK_SDC)"
	@cp "$(STA_LOCAL_STA_TCL)" "$(STA_WORK_STA_TCL)"
	set -o pipefail; \
	CLK_PORT_NAME=$(STA_CLK_PORT) CLK_FREQ_MHZ=$(STA_CLK_FREQ_MHZ) \
	"$(YOSYS_STA_DIR)/bin/iEDA" \
		-script "$(abspath $(STA_WORK_STA_TCL))" \
		"$(abspath $(STA_WORK_SDC))" \
		"$(abspath $(STA_WORK_DIR))/$(STA_MODULE)-$(STA_CLK_FREQ_MHZ)MHz/$(STA_MODULE).netlist.v" \
		"$(STA_MODULE)" \
		"$(PDK_NAME)" \
		"$(abspath $(YOSYS_STA_DIR))" \
		2>&1 | tee "$(abspath $(STA_WORK_DIR))/$(STA_MODULE)-$(STA_CLK_FREQ_MHZ)MHz/sta.log"
	@rm -rf "$(STA_OUT_DIR)"
	@cp -R "$(STA_WORK_DIR)" "$(STA_OUT_DIR)"

sta: sta-run

sta-module: sta-run

clean:
	$(MAKE) -C dv/cocotb clean
