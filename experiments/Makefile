.PHONY: verif lint synth sta list help

# ─── User variables ───────────────────────────────────────────────
MOD          ?= fa_recip_nr_q16_16
EXP          ?= base
CLK_FREQ_MHZ ?= 500
CLK_PORT     ?= clk
STA_DATE     ?= $(shell date +%Y%m%d)

# ─── Paths ────────────────────────────────────────────────────────
ROOT         := $(abspath ..)
YOSYS_STA_DIR ?= $(ROOT)/../ysyx/yosys-sta
PDK_SRC_DIR  ?= $(ROOT)/../ysyx/mac/pdk/icsprout55-pdk
PDK_NAME     ?= icsprout55

EXP_DIR      := $(abspath $(MOD)/$(EXP))
TB_DIR       := $(abspath $(MOD)/tb)
STA_OUT_DIR  := $(ROOT)/syn/exp_$(MOD)_$(EXP)_$(STA_DATE)
STA_WORK_DIR := $(YOSYS_STA_DIR)/flashattn_exp/$(MOD)_$(EXP)_$(STA_DATE)

STA_SDC_COMB    := $(ROOT)/syn/sdc/default_comb.sdc
STA_SDC_CLOCKED := $(ROOT)/syn/sdc/default_clocked.sdc
STA_LOCAL_TCL   := $(ROOT)/syn/scripts/sta_no_power.tcl

LINT_FLAGS   := --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC

PYTHON_BIN   ?= $(ROOT)/.venv/bin/python
COCOTB_CONFIG ?= $(ROOT)/.venv/bin/cocotb-config

SIM          ?= verilator
TOPLEVEL_LANG ?= verilog

# ─── Per-module configuration ─────────────────────────────────────
# RTL files: all .sv in the experiment directory
EXP_SV_FILES := $(wildcard $(EXP_DIR)/*.sv)

# Determine if the module is clocked (has clk port)
CLOCKED_MODULES := fa_row_reduction_core fa_online_softmax_update fa_recip_nr_q16_16
IS_CLOCKED := $(filter $(MOD),$(CLOCKED_MODULES))
STA_SDC_FILE := $(if $(IS_CLOCKED),$(STA_SDC_CLOCKED),$(STA_SDC_COMB))

# Top-level module name (same as MOD)
TOPLEVEL := $(MOD)

# ─── Targets ──────────────────────────────────────────────────────

help:
	@echo "FlashAttention Experiments Makefile"
	@echo ""
	@echo "Usage:"
	@echo "  make verif  MOD=<module> EXP=<experiment>"
	@echo "  make lint   MOD=<module> EXP=<experiment>"
	@echo "  make synth  MOD=<module> EXP=<experiment> [CLK_FREQ_MHZ=500]"
	@echo "  make sta    MOD=<module> EXP=<experiment> [CLK_FREQ_MHZ=500]"
	@echo "  make list"
	@echo ""
	@echo "Examples:"
	@echo "  make verif MOD=fa_recip_nr_q16_16 EXP=base"
	@echo "  make sta   MOD=fa_recip_nr_q16_16 EXP=exp_a CLK_FREQ_MHZ=500"

list:
	@echo "Available experiments:"
	@for mod in $(wildcard */); do \
		mod=$${mod%/}; \
		for exp in $$(ls -d $$mod/*/  2>/dev/null | grep -v '/tb/' | sed "s|$$mod/||;s|/||"); do \
			echo "  MOD=$$mod EXP=$$exp"; \
		done; \
	done

# ─── Verification (cocotb + verilator) ───────────────────────────
VERIF_BUILD  := $(abspath build/verif_$(MOD)_$(EXP))
VERIF_TEST   := $(wildcard $(TB_DIR)/test_$(MOD).py)
VERIF_MODULE := test_$(MOD)

verif:
	@test -d "$(EXP_DIR)" || (echo "[ERR] Experiment dir not found: $(EXP_DIR)" && exit 1)
	@test -f "$(TB_DIR)/test_$(MOD).py" || (echo "[ERR] Test not found: $(TB_DIR)/test_$(MOD).py" && exit 1)
	@mkdir -p $(VERIF_BUILD)
	VIRTUAL_ENV=$(ROOT)/.venv PATH=$(ROOT)/.venv/bin:$$PATH \
	SIM=$(SIM) TOPLEVEL_LANG=$(TOPLEVEL_LANG) TOPLEVEL=$(TOPLEVEL) \
	MODULE=$(VERIF_MODULE) \
	VERILOG_SOURCES="$(EXP_SV_FILES)" \
	SIM_BUILD=$(VERIF_BUILD) \
	COCOTB_RESULTS_FILE=$(VERIF_BUILD)/results.xml \
	EXTRA_ARGS="-Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL" \
	PYTHONPATH=$(TB_DIR):$(ROOT)/dv/cocotb/tests:$(PYTHONPATH) \
	EXP_NAME=$(EXP) \
	$(MAKE) -f $$($(COCOTB_CONFIG) --makefiles)/Makefile.sim

# ─── Lint ─────────────────────────────────────────────────────────
lint:
	@test -d "$(EXP_DIR)" || (echo "[ERR] Experiment dir not found: $(EXP_DIR)" && exit 1)
	verilator $(LINT_FLAGS) --top-module $(TOPLEVEL) $(EXP_SV_FILES)

# ─── Synthesis (yosys) ────────────────────────────────────────────
synth:
	@test -d "$(EXP_DIR)" || (echo "[ERR] Experiment dir not found: $(EXP_DIR)" && exit 1)
	@test -d "$(YOSYS_STA_DIR)" || (echo "[ERR] YOSYS_STA_DIR not found: $(YOSYS_STA_DIR)" && exit 1)
	@test -d "$(PDK_SRC_DIR)" || (echo "[ERR] PDK_SRC_DIR not found: $(PDK_SRC_DIR)" && exit 1)
	@mkdir -p "$(STA_WORK_DIR)"
	@mkdir -p "$(YOSYS_STA_DIR)/pdk"
	@ln -sfn "$(abspath $(PDK_SRC_DIR))" "$(YOSYS_STA_DIR)/pdk/$(PDK_NAME)"
	$(MAKE) -C $(YOSYS_STA_DIR) syn \
		DESIGN=$(MOD) \
		RTL_FILES="$(abspath $(EXP_SV_FILES))" \
		PDK=$(PDK_NAME) \
		CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
		CLK_PORT_NAME=$(CLK_PORT) \
		O=$(abspath $(STA_WORK_DIR))
	@rm -rf "$(STA_OUT_DIR)"
	@cp -R "$(STA_WORK_DIR)" "$(STA_OUT_DIR)"
	@echo "[SYNTH] Output: $(STA_OUT_DIR)"

# ─── STA (iEDA) ──────────────────────────────────────────────────
STA_WORK_SDC     := $(STA_WORK_DIR)/active_sta.sdc
STA_WORK_STA_TCL := $(STA_WORK_DIR)/sta_no_power.tcl

sta: synth
	@cp "$(STA_SDC_FILE)" "$(STA_WORK_SDC)"
	@cp "$(STA_LOCAL_TCL)" "$(STA_WORK_STA_TCL)"
	set -o pipefail; \
	CLK_PORT_NAME=$(CLK_PORT) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
	"$(YOSYS_STA_DIR)/bin/iEDA" \
		-script "$(abspath $(STA_WORK_STA_TCL))" \
		"$(abspath $(STA_WORK_SDC))" \
		"$(abspath $(STA_WORK_DIR))/$(MOD)-$(CLK_FREQ_MHZ)MHz/$(MOD).netlist.v" \
		"$(MOD)" \
		"$(PDK_NAME)" \
		"$(abspath $(YOSYS_STA_DIR))" \
		2>&1 | tee "$(abspath $(STA_WORK_DIR))/$(MOD)-$(CLK_FREQ_MHZ)MHz/sta.log"
	@rm -rf "$(STA_OUT_DIR)"
	@cp -R "$(STA_WORK_DIR)" "$(STA_OUT_DIR)"
	@echo "[STA] Output: $(STA_OUT_DIR)"
