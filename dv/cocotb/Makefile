include common.mk
include ../../cfg/module_targets.mk

.PHONY: test regress clean list

test:
	@echo "[COCOTB] Running MODULE=$(SELECTED_MODULE)"
	$(MAKE) -f $(COCOTB_MAKEFILE) \
		MODULE=$(MODULE_PY) \
		TOPLEVEL=$(TOPLEVEL) \
		SIM_BUILD=sim_build/$(SELECTED_MODULE) \
		COCOTB_RESULTS_FILE=sim_build/$(SELECTED_MODULE)/results.xml

regress:
	@set -e; \
	for m in $(MODULES); do \
		echo "[COCOTB] Regress $$m"; \
		$(MAKE) MODULE=$$m test; \
	done

list:
	@echo "Supported MODULES: $(MODULES)"

clean:
	rm -rf sim_build __pycache__ tests/__pycache__
