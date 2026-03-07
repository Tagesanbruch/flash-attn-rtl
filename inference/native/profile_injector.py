import re

with open("run.c", "r") as f:
    content = f.read()

# 1. Add profiling variables to global scope
globals_code = """
// --- Profiling Globals ---
long long total_macs_qkv = 0;
long long total_macs_attn = 0;
long long total_macs_o = 0;
long long total_macs_ffn = 0;

double time_qkv = 0;
double time_attn = 0;
double time_o = 0;
double time_ffn = 0;

static double get_time_sec() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}
// -----------------------
"""
content = re.sub(r'(#include <stdbool\.h>\n)', r'\1' + globals_code, content)

# 2. Inject into forward()
forward_orig = "float *forward(Transformer *transformer, int token, int pos,bool need_bias) {\n"
forward_new = forward_orig + "  double t0, t1;\n  int head_size = transformer->config.dim / transformer->config.n_heads;\n  int kv_dim = (transformer->config.dim * transformer->config.n_kv_heads) / transformer->config.n_heads;\n"

# Inside forward(), wrap matmuls with timing
# QKV
qkv_orig = """    // qkv matmuls for this position
    matmul(s->q, s->xb, w->wq + l * dim * dim, dim, dim);
    matmul(s->k, s->xb, w->wk + l * dim * kv_dim, dim, kv_dim);
    matmul(s->v, s->xb, w->wv + l * dim * kv_dim, dim, kv_dim);"""
qkv_new = """    t0 = get_time_sec();
    matmul(s->q, s->xb, w->wq + l * dim * dim, dim, dim);
    matmul(s->k, s->xb, w->wk + l * dim * kv_dim, dim, kv_dim);
    matmul(s->v, s->xb, w->wv + l * dim * kv_dim, dim, kv_dim);
    t1 = get_time_sec();
    time_qkv += (t1 - t0);
    total_macs_qkv += (long long)(dim * dim + 2 * dim * kv_dim);"""
content = content.replace(qkv_orig, qkv_new)

# ATTN
attn_orig = """    // multihead attention. iterate over all heads
    int h;
#pragma omp parallel for private(h)
    for (h = 0; h < p->n_heads; h++) {"""
attn_new = """    t0 = get_time_sec();
    // multihead attention. iterate over all heads
    int h;
#pragma omp parallel for private(h)
    for (h = 0; h < p->n_heads; h++) {"""
content = content.replace(attn_orig, attn_new)

attn_end_orig = """      }
    }

    // final matmul to get the output of the attention"""
attn_end_new = """      }
    }
    t1 = get_time_sec();
    time_attn += (t1 - t0);
    total_macs_attn += (long long)(2 * p->n_heads * (pos + 1) * head_size); // QK dot and AV dot

    // final matmul to get the output of the attention"""
content = content.replace(attn_end_orig, attn_end_new)

# O Matmul
o_orig = """    // final matmul to get the output of the attention
    matmul(s->xb2, s->xb, w->wo + l * dim * dim, dim, dim);"""
o_new = """    t0 = get_time_sec();
    matmul(s->xb2, s->xb, w->wo + l * dim * dim, dim, dim);
    t1 = get_time_sec();
    time_o += (t1 - t0);
    total_macs_o += (long long)(dim * dim);"""
content = content.replace(o_orig, o_new)

# FFN
ffn_orig = """    // Now for FFN in PyTorch we have: self.w2(F.silu(self.w1(x)) * self.w3(x))
    // first calculate self.w1(x) and self.w3(x)
    matmul(s->hb, s->xb, w->w1 + l * dim * hidden_dim, dim, hidden_dim);
    matmul(s->hb2, s->xb, w->w3 + l * dim * hidden_dim, dim, hidden_dim);

    // SwiGLU non-linearity
    for (int i = 0; i < hidden_dim; i++) {
      float val = s->hb[i];
      // silu(x)=x*σ(x), where σ(x) is the logistic sigmoid
      val *= (1.0f / (1.0f + expf(-val)));
      // elementwise multiply with w3(x)
      val *= s->hb2[i];
      s->hb[i] = val;
    }

    // final matmul to get the output of the ffn
    matmul(s->xb, s->hb, w->w2 + l * dim * hidden_dim, hidden_dim, dim);"""
ffn_new = """    t0 = get_time_sec();
    matmul(s->hb, s->xb, w->w1 + l * dim * hidden_dim, dim, hidden_dim);
    matmul(s->hb2, s->xb, w->w3 + l * dim * hidden_dim, dim, hidden_dim);
    for (int i = 0; i < hidden_dim; i++) {
      float val = s->hb[i];
      val *= (1.0f / (1.0f + expf(-val)));
      val *= s->hb2[i];
      s->hb[i] = val;
    }
    matmul(s->xb, s->hb, w->w2 + l * dim * hidden_dim, hidden_dim, dim);
    t1 = get_time_sec();
    time_ffn += (t1 - t0);
    total_macs_ffn += (long long)(3 * dim * hidden_dim);"""
content = content.replace(ffn_orig, ffn_new)


# 3. Print stats at the end of chat()
chat_end_orig = """  if (pos > 1) {
    long end = time_in_ms();"""
chat_end_new = """  if (pos > 1) {
    long end = time_in_ms();
    
    printf("\\n\\n--- PROFILING RESULTS ---\\n");
    printf("Variables   : pos=%d, prefill_tokens=%d\\n", pos, prompt_token_num);
    printf("Total MACs  : QKV=%.2f G, ATTN=%.2f G, O=%.2f G, FFN=%.2f G\\n", 
           total_macs_qkv/1e9, total_macs_attn/1e9, total_macs_o/1e9, total_macs_ffn/1e9);
    printf("Total Time  : QKV=%.3fs, ATTN=%.3fs, O=%.3fs, FFN=%.3fs\\n", 
           time_qkv, time_attn, time_o, time_ffn);
    printf("Perf (GMAC/s): QKV=%.2f, ATTN=%.2f, O=%.2f, FFN=%.2f\\n",
           (total_macs_qkv/1e9)/time_qkv, (total_macs_attn/1e9)/time_attn, 
           (total_macs_o/1e9)/time_o, (total_macs_ffn/1e9)/time_ffn);
    
    // Convert to GOPS (2 OPS per MAC)
    double time_all = time_qkv + time_attn + time_o + time_ffn;
    long long total_macs = total_macs_qkv + total_macs_attn + total_macs_o + total_macs_ffn;
    printf("\\nOverall Engine: %.2f GMAC/s (%.2f GOPS)\\n", (total_macs/1e9)/time_all, 2*(total_macs/1e9)/time_all);
    printf("ATTN fraction of time: %.1f%%\\n", 100.0 * time_attn / time_all);
    printf("---------------------------\\n\\n");
"""
content = content.replace(chat_end_orig, chat_end_new)

with open("run_profiled.c", "w") as f:
    f.write(content)

print("Injected profiling code.")
