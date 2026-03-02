.PHONY: setup-py test regress list clean lint

MODULE ?= fa_mul_sat_q8_8
LINT_FLAGS := --lint-only -Wall -Wno-UNUSEDSIGNAL

setup-py:
	uv venv .venv
	uv pip install --python .venv/bin/python 'cocotb==1.9.2' pytest

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

clean:
	$(MAKE) -C dv/cocotb clean
