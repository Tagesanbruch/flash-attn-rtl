import os
import subprocess
import csv
import re

prompts = [
    "What is the capital of France?",
    "Explain the theory of relativity in simple terms.",
    "Write a short poem about a mechanical AI.",
    "What are the main differences between Python and C?",
    "How does a standard transformer architecture work?",
    "Who painted the Mona Lisa?",
    "Provide a recipe for classic chocolate chip cookies.",
    "Summarize the plot of the movie Inception.",
    "What is the history of the Apple company?",
    "Can you explain the baseline specification of Flash Attention?"
]

def run_inference(executable, prompt):
    print(f"Running {executable}...")
    try:
        result = subprocess.run(
            [f"./build/{executable}", prompt],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=120
        )
        output = result.stdout
        # 1. Extract Text
        ans_match = re.search(r"Answer:\s*\n(.*?)(?:\n=+\n|achieved prefill|$)", output, re.DOTALL)
        if ans_match:
            text_response = ans_match.group(1).strip()
        else:
            text_response = "[Parse Error] " + output.strip()[:100]
            
        # 2. Extract Performance Dict
        perf = {
            "Tokens": "",
            "QKV_Speed(GMAC/s)": "",
            "ATTN_Speed(GMAC/s)": "",
            "Pipeline_Tput(GMAC/s)": "",
            "ATTN_Time_%": ""
        }
        
        tokens_match = re.search(r"Tokens\s*:\s*(.*?)\n", output)
        if tokens_match: perf["Tokens"] = tokens_match.group(1).strip()
            
        speed_match = re.search(r"Speed\(GMAC/s\):\s*QKV=\s*([0-9.]+),\s*ATTN=\s*([0-9.]+)", output)
        if speed_match:
            perf["QKV_Speed(GMAC/s)"] = speed_match.group(1)
            perf["ATTN_Speed(GMAC/s)"] = speed_match.group(2)
            
        tput_match = re.search(r">>> Pipeline Tput:\s*([0-9.]+)", output)
        if tput_match: perf["Pipeline_Tput(GMAC/s)"] = tput_match.group(1)
            
        attin_time_match = re.search(r">>> ATTN time-%  :\s*([0-9.]+)", output)
        if attin_time_match: perf["ATTN_Time_%"] = attin_time_match.group(1)
            
        return text_response, perf
        
    except subprocess.TimeoutExpired:
        return "[TIMEOUT]", {}
    except Exception as e:
        return f"[ERROR] {str(e)}", {}

def main():
    print("Building executables...")
    os.system("make build/runperf") # ensure fp32 is built
    os.system("make run_fa")        # ensure q8.8 is built
    
    text_results = []
    perf_results = []
    
    for i, prompt in enumerate(prompts):
        print(f"\\n--- Testing Prompt {i+1}/10 ---")
        prompt_clean = prompt.replace('"', '\\\\"') # escape for shell
        
        print(f"Prompt: {prompt}")
        
        fp32_res, fp32_perf = run_inference("runperf", prompt_clean)
        q88_res, q88_perf = run_inference("run_fa", prompt_clean)
        
        match_status = "YES" if fp32_res == q88_res else "NO"
        
        # text row
        text_results.append({
            "Prompt": prompt,
            "FP32 Output": fp32_res,
            "Q8.8 Output": q88_res,
            "Match?": match_status
        })
        
        # perf row FP32
        perf_row_fp32 = {"Prompt": prompt, "Model": "FP32(runperf)"}
        perf_row_fp32.update(fp32_perf)
        perf_results.append(perf_row_fp32)
        
        # perf row Q8.8
        perf_row_q88 = {"Prompt": prompt, "Model": "Q8.8(run_fa)"}
        perf_row_q88.update(q88_perf)
        perf_results.append(perf_row_q88)

    # Save to CSV - TEXT
    text_csv = "q8_8_text_results.csv"
    with open(text_csv, mode='w', newline='', encoding='utf-8') as file:
        writer = csv.DictWriter(file, fieldnames=["Prompt", "FP32 Output", "Q8.8 Output", "Match?"])
        writer.writeheader()
        for row in text_results:
            writer.writerow(row)
            
    # Save to CSV - PERF
    perf_csv = "q8_8_perf_results.csv"
    with open(perf_csv, mode='w', newline='', encoding='utf-8') as file:
        fieldnames = ["Prompt", "Model", "Tokens", "QKV_Speed(GMAC/s)", "ATTN_Speed(GMAC/s)", "Pipeline_Tput(GMAC/s)", "ATTN_Time_%"]
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        writer.writeheader()
        for row in perf_results:
            writer.writerow(row)
            
    # Print Summary
    print("\\n\\n=== SUMARY ===")
    matches = sum(1 for r in text_results if r["Match?"] == "YES")
    print(f"Exact Matches: {matches} / {len(prompts)}")
    print(f"Text results saved to {text_csv}")
    print(f"Perf results saved to {perf_csv}")

if __name__ == "__main__":
    main()
