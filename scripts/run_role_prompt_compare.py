#!/usr/bin/env python3
import os
import re
import subprocess
from pathlib import Path

base = Path('/Volumes/disk/work/flashattn/inference/native')
exe_map = {
    'sw': base / 'build/run_fa',
    'cmodel': base / 'build/run_fa_cmodel',
}

prompts = [
    "system: You are a helpful assistant.\nuser: hello\nassistant:",
    "system: 你是一个中文助手。\nuser: 请简短介绍你自己\nassistant:",
    "system: You are a math tutor.\nuser: what is 1+1?\nassistant:",
]

log_dir = base / 'logs'
log_dir.mkdir(exist_ok=True)
rows = []

for backend in ['sw', 'cmodel']:
    for idx, prompt in enumerate(prompts, 1):
        env = dict(os.environ)
        env.update({
            'RUN_FA_SIMPLE_PROMPT': '1',
            'RUN_FA_DEBUG_TOPK': '5',
            'RUN_FA_DEBUG_DECODE_TOKENS': '1',
            'RUN_FA_STOP_AFTER_DECODE_TOKENS': '16',
            'FLASH_ATTN_BACKEND': backend,
            'RUN_FA_DEBUG_FILE': str(log_dir / f'{backend}_role_prompt{idx}_decode16.log'),
        })
        proc = subprocess.run(
            [str(exe_map[backend]), prompt],
            cwd=str(base),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        out = proc.stdout
        (log_dir / f'{backend}_role_prompt{idx}.stdout.log').write_text(out)

        ans = ''
        m = re.search(r'Answer:\s*\n([\s\S]*?)\nachieved prefill tok/s:', out)
        if m:
            ans = m.group(1).strip().replace('\n', '\\n')
        p = re.search(r'achieved prefill tok/s:\s*([0-9.]+)', out)
        d = re.search(r'achieved decode tok/s:\s*([0-9.]+)', out)

        rows.append({
            'backend': backend,
            'prompt_id': idx,
            'rc': proc.returncode,
            'prefill': float(p.group(1)) if p else -1.0,
            'decode': float(d.group(1)) if d else -1.0,
            'answer': ans,
        })

summary = log_dir / 'role_prompt_compare_summary.txt'
with summary.open('w') as f:
    for row in rows:
        f.write(f"backend={row['backend']} prompt_id={row['prompt_id']} rc={row['rc']} ")
        f.write(f"prefill={row['prefill']:.6f} decode={row['decode']:.6f}\n")
        f.write(f"answer={row['answer']}\n")
        f.write('---\n')

print(f'wrote {summary}')
for row in rows:
    print(f"backend={row['backend']} prompt_id={row['prompt_id']} rc={row['rc']} prefill={row['prefill']:.3f} decode={row['decode']:.3f}")
    print(f"ans={row['answer'][:120]}")
    print('-----')
