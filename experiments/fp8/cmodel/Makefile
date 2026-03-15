PYTHON ?= python3
OUT_DIR ?= out
CSV_OUT ?= $(OUT_DIR)/fp8_cmodel_report.csv

.PHONY: run clean

run:
	@mkdir -p $(OUT_DIR)
	$(PYTHON) fp8_attention_cmodel.py \
		--s 256 --d 64 --seed 20260315 --n-seeds 3 \
		--csv-out $(CSV_OUT)

clean:
	rm -rf $(OUT_DIR)
