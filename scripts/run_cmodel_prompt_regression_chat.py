#!/usr/bin/env python3
import os
import re
import subprocess
from pathlib import Path

base = Path('/Volumes/disk/work/flashattn/inference/native')
exe = base / 'build/run_fa_cmodel'
log_dir = base / 'logs'
log_dir.mkdir(exist_ok=True)

prompts = [
    'hello',
    'who are you',
    'what is 1+1?',
    '请用一句话介绍你自己',
    'write a short greeting',
]

rows = []
for i, prompt in enumerate(prompts, 1):
    dbg = log_dir / f'cmodel_chat_prompt{i}_decode16.log'
    env = dict(os.environ)
    env.update({
        'RUN_FA_DEBUG_TOPK': '5',
        'RUN_FA_DEBUG_DECODE_TOKENS': '1',
        'RUN_FA_STOP_AFTER_DECODE_TOKENS': '16',
        'RUN_FA_DEBUG_FILE': str(dbg),
        'FLASH_ATTN_BACKEND': 'cmodel',
    })

    proc = subprocess.run(
        [str(exe), prompt],
        cwd=str(base),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    out = proc.stdout
    (log_dir / f'cmodel_chat_prompt{i}.stdout.log').write_text(out)

    ans = ''
    match = re.search(r'Answer:\s*\n([\s\S]*?)\nachieved prefill tok/s:', out)
    if match:
        ans = match.group(1).strip().replace('\n', '\\n')

    prefill = re.search(r'achieved prefill tok/s:\s*([0-9.]+)', out)
    decode = re.search(r'achieved decode tok/s:\s*([0-9.]+)', out)

    rows.append({
        'prompt': prompt,
        'answer': ans,
        'prefill': float(prefill.group(1)) if prefill else -1.0,
        'decode': float(decode.group(1)) if decode else -1.0,
        'rc': proc.returncode,
    })

report = log_dir / 'cmodel_prompt_regression_chat_summary.txt'
with report.open('w') as f:
    for row in rows:
        f.write(f"prompt={row['prompt']}\n")
        f.write(f"rc={row['rc']} prefill_toks={row['prefill']:.6f} decode_toks={row['decode']:.6f}\n")
        f.write(f"answer={row['answer']}\n")
        f.write('---\n')

print(f'wrote {report}')
for row in rows:
    print(f"PROMPT: {row['prompt']}")
    print(f"RC={row['rc']} prefill={row['prefill']:.4f} decode={row['decode']:.4f}")
    print(f"ANS={row['answer'][:140]}")
    print('-----')
