#!/usr/bin/env python3
import os
import re
import subprocess
from pathlib import Path

base = Path(__file__).resolve().parent.parent / 'inference/native'
exe = base / 'build/run_fa_cmodel'
log_dir = base / 'logs'
log_dir.mkdir(exist_ok=True)

# We use the prompt that fails structurally
prompt = "system: 你是一个中文助手。\nuser: 请简短介绍你自己\nassistant:"

def run_backend(log_prefix, backend='cmodel', env_updates={}):
    env = dict(os.environ)
    dbg = log_dir / f'{log_prefix}_decode64.log'
    env.update({
        'RUN_FA_SIMPLE_PROMPT': '1',
        'RUN_FA_DEBUG_TOPK': '10',  # capture 10 logits for deep comparison
        'RUN_FA_DEBUG_DECODE_TOKENS': '1',
        'RUN_FA_STOP_AFTER_DECODE_TOKENS': '64',
        'RUN_FA_DEBUG_FILE': str(dbg),
        'FLASH_ATTN_BACKEND': backend,
        **env_updates
    })

    proc = subprocess.run(
        [str(exe), prompt],
        cwd=str(base),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    (log_dir / f'{log_prefix}.stdout.log').write_text(proc.stdout)
    return dbg

def parse_log(dbg_file):
    # topk pos=20 k0=1474:13.147568 k1=6352:13.111828
    # decode pos=21 token=1474 piece='User'
    
    tokens = {}
    logits = {}
    
    with open(dbg_file, 'r') as f:
        for line in f:
            if line.startswith('decode pos='):
                m = re.search(r'pos=(\d+) token=(\d+) piece=\'(.*)\'', line)
                if m:
                    pos = int(m.group(1))
                    token = int(m.group(2))
                    piece = m.group(3)
                    tokens[pos] = (token, piece)
            elif line.startswith('topk pos='):
                m = re.search(r'pos=(\d+)', line)
                if m:
                    pos = int(m.group(1))
                    k_str = line[m.end():].strip()
                    k_dict = {}
                    for kv in k_str.split():
                        idx_val = kv.split('=')[1].split(':')
                        vocab_id = int(idx_val[0])
                        val = float(idx_val[1])
                        k_dict[vocab_id] = val
                    logits[pos] = k_dict
    
    return tokens, logits

def find_first_divergence(baseline_toks, baseline_logs, test_toks, test_logs):
    diverge_pos = None
    common_positions = sorted(list(set(baseline_toks.keys()) & set(test_toks.keys())))
    
    for pos in common_positions:
        if baseline_toks[pos][0] != test_toks[pos][0]:
            diverge_pos = pos
            break
            
    return diverge_pos

def analyze_divergence(diverge_pos, baseline_toks, baseline_logs, test_toks, test_logs):
    if diverge_pos is None:
        return "No divergence found in decoded tokens!"
    
    ref_tok = baseline_toks[diverge_pos]
    tst_tok = test_toks[diverge_pos]
    
    # Logits correspond to creating the token at `diverge_pos`.
    # Usually `topk pos=N-1` dictates `decode pos=N`
    # Let's align on pos-1
    logit_pos = diverge_pos - 1
    ref_l = baseline_logs.get(logit_pos, {})
    tst_l = test_logs.get(logit_pos, {})
    
    res = []
    res.append(f"First Divergence at Pos: {diverge_pos}")
    res.append(f"Baseline Token: {ref_tok[0]} ({ref_tok[1]})")
    res.append(f"Test Token:     {tst_tok[0]} ({tst_tok[1]})")
    
    res.append(f"\nBaseline Top-K Logits at pos {logit_pos}:")
    for k, v in sorted(ref_l.items(), key=lambda item: item[1], reverse=True)[:5]:
        res.append(f"  Token {k:5d}: {v:8.4f}")
        
    res.append(f"\nTest Top-K Logits at pos {logit_pos}:")
    for k, v in sorted(tst_l.items(), key=lambda item: item[1], reverse=True)[:5]:
        res.append(f"  Token {k:5d}: {v:8.4f}")
        
    # See where the baseline's chosen token ranks in the test's logits
    test_score_for_ref_tok = tst_l.get(ref_tok[0], 'Not in Top-K')
    res.append(f"\nTest score for Baseline Token {ref_tok[0]}: {test_score_for_ref_tok}")
    
    # See where the test's chosen token ranks in the baseline's logits
    ref_score_for_tst_tok = ref_l.get(tst_tok[0], 'Not in Top-K')
    res.append(f"Baseline score for Test Token {tst_tok[0]}: {ref_score_for_tst_tok}")
    
    return "\n".join(res)

print("Running Mode 14 (Stable Reference)...")
ref_dbg = run_backend('sweep_ref_mode14', env_updates={'FLASH_ATTN_CMODEL_MODE': '14'})

print("Running Mode 17 (Chunk=8 Test)...")
tst_dbg = run_backend('sweep_tst_mode17', env_updates={'FLASH_ATTN_CMODEL_MODE': '17', 'FLASH_ATTN_CMODEL_K_SMOOTH': '1'})

ref_toks, ref_logs = parse_log(ref_dbg)
tst_toks, tst_logs = parse_log(tst_dbg)

diverge_pos = find_first_divergence(ref_toks, ref_logs, tst_toks, tst_logs)
analysis = analyze_divergence(diverge_pos, ref_toks, ref_logs, tst_toks, tst_logs)

report = log_dir / 'first_divergence_analysis.txt'
report.write_text(analysis)
print("\n--- Divergence Report ---")
print(analysis)
print(f"-------------------------\n(Report saved to {report})")
