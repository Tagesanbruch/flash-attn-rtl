import os
import struct
import json
import torch
import numpy as np
from safetensors.torch import load_file
from pathlib import Path

def serialize_fp32(file, tensor):
    d = tensor.detach().cpu().view(-1).to(torch.float32).numpy()
    b = struct.pack(f'{len(d)}f', *d)
    file.write(b)

def serialize_fp8(file, tensor):
    d = tensor.detach().cpu().view(torch.int8).numpy()
    file.write(d.tobytes())

def export_fp8(model_path, output_path):
    with open(os.path.join(model_path, "config.json"), "r") as f:
        config = json.load(f)
    
    dim = config["hidden_size"]
    n_layers = config["num_hidden_layers"]
    n_heads = config["num_attention_heads"]
    n_kv_heads = config["num_key_value_heads"]
    vocab_size = config["vocab_size"]
    hidden_dim = config["intermediate_size"]
    seq_len = config["max_position_embeddings"]
    
    out_file = open(output_path, "wb")
    header = struct.pack('iiiiiii', dim, hidden_dim, n_layers, n_heads, n_kv_heads, vocab_size, seq_len)
    out_file.write(header)
    
    weights = load_file(os.path.join(model_path, "model.safetensors"))
    
    # 1. token_embedding_table
    serialize_fp32(out_file, weights["model.embed_tokens.weight"])
    
    # 2. rms_att_weight
    for i in range(n_layers):
        serialize_fp32(out_file, weights[f"model.layers.{i}.input_layernorm.weight"])
        
    # 3. wq + sq
    for i in range(n_layers): serialize_fp8(out_file, weights[f"model.layers.{i}.self_attn.q_proj.weight"])
    for i in range(n_layers): serialize_fp32(out_file, weights[f"model.layers.{i}.self_attn.q_proj.weight_scale_inv"])
        
    # 4. wk + sk
    for i in range(n_layers): serialize_fp8(out_file, weights[f"model.layers.{i}.self_attn.k_proj.weight"])
    for i in range(n_layers): serialize_fp32(out_file, weights[f"model.layers.{i}.self_attn.k_proj.weight_scale_inv"])
        
    # 5. wv + sv
    for i in range(n_layers): serialize_fp8(out_file, weights[f"model.layers.{i}.self_attn.v_proj.weight"])
    for i in range(n_layers): serialize_fp32(out_file, weights[f"model.layers.{i}.self_attn.v_proj.weight_scale_inv"])
        
    # 6. wo + so
    for i in range(n_layers): serialize_fp8(out_file, weights[f"model.layers.{i}.self_attn.o_proj.weight"])
    for i in range(n_layers): serialize_fp32(out_file, weights[f"model.layers.{i}.self_attn.o_proj.weight_scale_inv"])
        
    # 7. rms_ffn_weight
    for i in range(n_layers):
        serialize_fp32(out_file, weights[f"model.layers.{i}.post_attention_layernorm.weight"])
        
    # 8. w1 + s1
    for i in range(n_layers): serialize_fp8(out_file, weights[f"model.layers.{i}.mlp.gate_proj.weight"])
    for i in range(n_layers): serialize_fp32(out_file, weights[f"model.layers.{i}.mlp.gate_proj.weight_scale_inv"])
        
    # 9. w2 + s2
    for i in range(n_layers): serialize_fp8(out_file, weights[f"model.layers.{i}.mlp.down_proj.weight"])
    for i in range(n_layers): serialize_fp32(out_file, weights[f"model.layers.{i}.mlp.down_proj.weight_scale_inv"])
        
    # 10. w3 + s3
    for i in range(n_layers): serialize_fp8(out_file, weights[f"model.layers.{i}.mlp.up_proj.weight"])
    for i in range(n_layers): serialize_fp32(out_file, weights[f"model.layers.{i}.mlp.up_proj.weight_scale_inv"])
        
    # 11. rms_final_weight
    serialize_fp32(out_file, weights["model.norm.weight"])
    
    # 12. wcls
    serialize_fp32(out_file, weights["lm_head.weight"])
    
    out_file.close()
    print(f"Exported to {output_path}")

if __name__ == "__main__":
    export_fp8("Qwen3-1.7B-FP8", "Qwen3-1.7B-FP8.bin")