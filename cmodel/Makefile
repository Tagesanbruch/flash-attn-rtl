CXX ?= g++
CXXFLAGS ?= -O3 -std=c++17 -Wall -Wextra

BUILD_DIR := build
BIN := $(BUILD_DIR)/attention_cmodel
SRCS := \
	csrc/attention_cmodel.cpp \
	csrc/attention_lib.cpp \
	csrc/attention_math.cpp \
	csrc/attention_kernels.cpp \
	csrc/attention_experiment.cpp

.PHONY: all build run run-noncausal run-gaussian run-gaussian-noncausal sweep run-mask-sweep run-stage-decomp run-solution-compare run-solution-compare-tuned clean

all: build

build: $(BIN)

$(BIN): $(SRCS)
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(SRCS) -o $(BIN)

run: build
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode small-int --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_cmodel_modes_s256d64_causal.csv

run-noncausal: build
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --non-causal --input-mode small-int --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_cmodel_modes_s256d64_noncausal.csv

run-gaussian: build
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode gaussian --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_cmodel_modes_s256d64_causal_gaussian.csv

run-gaussian-noncausal: build
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --non-causal --input-mode gaussian --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_cmodel_modes_s256d64_noncausal_gaussian.csv

sweep: build run run-noncausal run-gaussian run-gaussian-noncausal

run-mask-sweep: build
	@echo "[cmodel] Causal mask sweep (small-int input, 5 seeds)"
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode small-int --mask-mode neg --neg-large-q8_8 -2048 --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_cmodel_mask_sweep_neg8.csv
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode small-int --mask-mode neg --neg-large-q8_8 -4096 --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_cmodel_mask_sweep_neg16.csv
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode small-int --mask-mode neg --neg-large-q8_8 -6144 --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_cmodel_mask_sweep_neg24.csv
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode small-int --mask-mode neg --neg-large-q8_8 -8192 --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_cmodel_mask_sweep_neg32.csv
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode small-int --mask-mode hard --neg-large-q8_8 -2048 --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_cmodel_mask_sweep_hard.csv

run-stage-decomp: build
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode small-int --seed 20260303 --n-seeds 1 \
		--run-stage-decomp --stage-seed 20260303 --stage-csv-out ../docs/data/20260304_stage_decomp_smallint_causal.csv
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode gaussian --seed 20260303 --n-seeds 1 \
		--run-stage-decomp --stage-seed 20260303 --stage-csv-out ../docs/data/20260304_stage_decomp_gaussian_causal.csv

run-solution-compare: build
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode small-int --mask-mode neg --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_solution_compare_smallint_causal_neg.csv
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode small-int --mask-mode hard --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_solution_compare_smallint_causal_hard.csv
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode gaussian --mask-mode neg --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_solution_compare_gaussian_causal_neg.csv
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode gaussian --mask-mode hard --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_solution_compare_gaussian_causal_hard.csv
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --non-causal --input-mode small-int --mask-mode neg --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_solution_compare_smallint_noncausal_neg.csv

run-solution-compare-tuned: build
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode small-int --mask-mode neg --neg-large-q8_8 -8192 --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_solution_compare_smallint_causal_neg32.csv
	$(BIN) --s 256 --d 64 --tq 32 --tk 64 --causal --input-mode gaussian --mask-mode neg --neg-large-q8_8 -8192 --seed 20260303 --n-seeds 5 \
		--csv-out ../docs/data/20260304_solution_compare_gaussian_causal_neg32.csv

clean:
	rm -rf $(BUILD_DIR)
