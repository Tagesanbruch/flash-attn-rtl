# Makefile

QWEN_HF_PATH ?= /Volumes/disk/FPGAEva/gemma_gguf/Qwen2.5-0.5B-Instruct
QWEN_BIN_MODEL_PATH ?= Qwen2.5-0.5B-Instruct.bin
QWEN_BIN_TOKEN_PATH ?= tokenizer.bin
# CC ?= gcc # or clang
CC=/opt/homebrew/opt/llvm/bin/clang
CXX=/opt/homebrew/opt/llvm/bin/clang++
########## Shared lib ###########
USE_PYTHON_TOKEN_SO = run_with_python_tokenizer.so
USE_C_TOKEN_SO = run_with_c_tokenizer.so

${USE_PYTHON_TOKEN_SO}: run.c ${QWEN_BIN_MODEL_PATH} Makefile
	$(CC) -shared -fPIC -Ofast -fopenmp -DWITHOUT_C_EN_DECODE -DQWEN_BIN_MODEL_PATH='"${QWEN_BIN_MODEL_PATH}"' -DQWEN_BIN_TOKEN_PATH='"${QWEN_BIN_TOKEN_PATH}"' -march=native run.c -lm  -o ${USE_PYTHON_TOKEN_SO}

${USE_C_TOKEN_SO}: run.c ${QWEN_BIN_MODEL_PATH} ${QWEN_BIN_TOKEN_PATH} Makefile
	$(CC) -shared -fPIC -Ofast -fopenmp -DWITH_C_EN_DECODE -DQWEN_BIN_MODEL_PATH='"${QWEN_BIN_MODEL_PATH}"' -DQWEN_BIN_TOKEN_PATH='"${QWEN_BIN_TOKEN_PATH}"' -march=native run.c -lm  -o ${USE_C_TOKEN_SO}

########## Hf Model ###########
${QWEN_HF_PATH}:
	@if [ ! -f "${QWEN_HF_PATH}" ]; then \
		echo "Error: ${QWEN_HF_PATH} does not exist!"; \
		exit 1; \
	fi

########## Export bin Model ###########
${QWEN_BIN_MODEL_PATH}: ${QWEN_HF_PATH}
	python export/export_qwen2_bin.py ${QWEN_BIN_MODEL_PATH} --hf=${QWEN_HF_PATH};
	

${QWEN_BIN_TOKEN_PATH}: ${QWEN_HF_PATH} 
	python export/export_token_bin.py ${QWEN_HF_PATH} ${QWEN_BIN_TOKEN_PATH}

######### Define some names for so #######

QWEN3_FP8_BIN_PATH ?= Qwen3-1.7B-FP8.bin

########## Plain C run ###########
all_c_infer: run.c ${QWEN_BIN_MODEL_PATH} ${QWEN_BIN_TOKEN_PATH}
	mkdir -p build
	$(CC) -Ofast -fopenmp -march=native -DNORMAL -DQWEN_BIN_MODEL_PATH='"${QWEN_BIN_MODEL_PATH}"' -DQWEN_BIN_TOKEN_PATH='"${QWEN_BIN_TOKEN_PATH}"' run.c  -lm  -o build/run

########## C-Model Flash Attention (Q8.8) ###########
run_fa: run_fa.c flash_attn.c
	mkdir -p build
	$(CC) -Ofast -fopenmp -march=native -DNORMAL -DQWEN_BIN_MODEL_PATH='"${QWEN_BIN_MODEL_PATH}"' -DQWEN_BIN_TOKEN_PATH='"${QWEN_BIN_TOKEN_PATH}"' run_fa.c flash_attn.c -lm -o build/run_fa

########## FP8 run ###########
run_fp8: run-fp8.c ${QWEN3_FP8_BIN_PATH} ${QWEN_BIN_TOKEN_PATH}
	mkdir -p build
	$(CC) -Ofast -fopenmp -march=native -DQWEN_BIN_MODEL_PATH='"${QWEN3_FP8_BIN_PATH}"' -DQWEN_BIN_TOKEN_PATH='"${QWEN_BIN_TOKEN_PATH}"' run-fp8.c -lm -o build/run-fp8

########## Accuracy test ################
acc_eva: ${USE_PYTHON_TOKEN_SO}
	python eva/acc.py --hf_path ${QWEN_HF_PATH} --so_path $(shell realpath ${USE_PYTHON_TOKEN_SO}) --bench_path eva/dev.tsv

########## FP8 Verification ################
fp8_eva: run_fp8
	python3 verify_fp8.py

########## Throughput test ###########
thpt_eva: ${USE_C_TOKEN_SO}
	python eva/python_c_throughput.py --so_path $(shell realpath ${USE_C_TOKEN_SO}) --bench_path eva/prompt.txt

########## Compress ratio test ###########
comp_eva:
	python eva/gen_comp_rate.py

clean:
	rm -f ./*.so
	rm -rf ./build