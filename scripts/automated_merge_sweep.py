#!/usr/bin/env python3
import os
import re
import subprocess
from pathlib import Path

base = Path(__file__).resolve().parent.parent / 'inference/native'
exe = base / 'build/run_fa_cmodel'
log_dir = base / 'logs/sweep'
log_dir.mkdir(exist_ok=True, parents=True)

prompt = "system: 你是一个中文助手。\nuser: 请简短介绍你自己\nassistant:"

def run_backend(log_prefix, backend='cmodel', env_updates={}):
    env = dict(os.environ)
    dbg = log_dir / f'{log_prefix}_decode.log'
    env.update({
        'RUN_FA_SIMPLE_PROMPT': '1',
        'RUN_FA_DEBUG_TOPK': '10',
        'RUN_FA_DEBUG_DECODE_TOKENS': '1',
        'RUN_FA_STOP_AFTER_DECODE_TOKENS': '96',
        'RUN_FA_DEBUG_FILE': str(dbg),
        'FLASH_ATTN_BACKEND': backend,
        **env_updates
    })

    subprocess.run(
        [str(exe), prompt],
        cwd=str(base),
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return dbg

def parse_log(dbg_file):
    tokens = {}
    if not dbg_file.exists():
        return tokens
    with open(dbg_file, 'r') as f:
        for line in f:
            if line.startswith('decode pos='):
                m = re.search(r'pos=(\d+) token=(\d+)', line)
                if m:
                    pos = int(m.group(1))
                    token = int(m.group(2))
                    tokens[pos] = token
    return tokens

print("Generating Baseline Mode 14...")
ref_dbg = run_backend('ref_mode14', env_updates={'FLASH_ATTN_CMODEL_MODE': '14', 'FLASH_ATTN_CMODEL_K_SMOOTH': '1'})
ref_toks = parse_log(ref_dbg)
if not ref_toks:
    print("Baseline generation failed!")
    exit(1)

chunks = [8, 16, 24, 32]
shifts = [0, 1]
biases = [0, 1]

results = []

print(f"{'Chunk':<6} | {'PV_Shift':<8} | {'RoundBias':<9} | {'Diverge Pos':<12}")
print("-" * 45)

for c in chunks:
    for s in shifts:
        for b in biases:
            config_name = f"tgt_c{c}_s{s}_b{b}"
            
            env = {
                'FLASH_ATTN_CMODEL_MODE': '17',
                'FLASH_ATTN_CMODEL_K_SMOOTH': '1',
                'FLASH_ATTN_CMODEL_CHUNK_SIZE': str(c),
                'FLASH_ATTN_CMODEL_PV_SHIFT': str(s),
                'FLASH_ATTN_CMODEL_ROUND_BIAS': str(b)
            }
            
            tgt_dbg = run_backend(config_name, env_updates=env)
            tgt_toks = parse_log(tgt_dbg)
            
            diverge_pos = None
            common_positions = sorted(list(set(ref_toks.keys()) & set(tgt_toks.keys())))
            
            for pos in common_positions:
                if ref_toks[pos] != tgt_toks[pos]:
                    diverge_pos = pos
                    break
            
            if diverge_pos is None and len(tgt_toks) < len(ref_toks):
                diverge_pos = len(tgt_toks) + 1  # Diverged by crashing short
                res_str = f"Short ({len(tgt_toks)})"
            else:
                res_str = str(diverge_pos) if diverge_pos else "None (Match!)"
                
            results.append((c, s, b, diverge_pos or 9999))
            
            print(f"{c:<6} | {s:<8} | {b:<9} | {res_str:<12}")

best = sorted(results, key=lambda x: x[3], reverse=True)
print("\nTop 3 Configurations:")
for i, (c, s, b, div) in enumerate(best[:3]):
    if div == 9999:
        d_str = "None (Perfect Match within 64 tokens)"
    else:
        d_str = f"Pos {div}"
    print(f"#{i+1}: Chunk={c}, PV_Shift={s}, RoundBias={b} -> Diverges at {d_str}")

report_file = base / 'logs/sweep/merge_scan_results.txt'
with open(report_file, 'w') as f:
    for c, s, b, div in results:
        f.write(f"{c},{s},{b},{div}\n")
