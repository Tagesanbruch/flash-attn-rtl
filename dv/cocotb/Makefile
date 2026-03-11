include common.mk
include ../../cfg/module_targets.mk

.PHONY: test regress clean list

test:
	@echo "[COCOTB] Running MODULE=$(SELECTED_MODULE)"
	VIRTUAL_ENV=$(ROOT_DIR)/.venv PATH=$(ROOT_DIR)/.venv/bin:$$PATH \
	$(MAKE) -f $(COCOTB_MAKEFILE) \
		MODULE=$(MODULE_PY) \
		TOPLEVEL=$(TOPLEVEL) \
		SIM_BUILD=$(SIM_BUILD) \
		COCOTB_RESULTS_FILE=$(COCOTB_RESULTS_FILE)

regress:
	@set -e; \
	for m in $(MODULES); do \
		echo "[COCOTB] Regress $$m"; \
		VIRTUAL_ENV=$(ROOT_DIR)/.venv PATH=$(ROOT_DIR)/.venv/bin:$$PATH $(MAKE) MODULE=$$m test; \
	done

list:
	@echo "Supported MODULES: $(MODULES)"

clean:
	rm -rf sim_build __pycache__ tests/__pycache__
