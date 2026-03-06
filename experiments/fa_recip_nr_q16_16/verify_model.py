#!/usr/bin/env python3
"""Bit-accurate model of RTL to verify exact behavior before/after fixes."""
import random

def clz32(val):
    if val == 0: return 32
    n = 0
    v = val & 0xFFFFFFFF
    if (v >> 16) == 0: n += 16; v <<= 16
    v &= 0xFFFFFFFF
    if (v >> 24) == 0: n += 8; v <<= 8
    v &= 0xFFFFFFFF
    if (v >> 28) == 0: n += 4; v <<= 4
    v &= 0xFFFFFFFF
    if (v >> 30) == 0: n += 2; v <<= 2
    v &= 0xFFFFFFFF
    if (v >> 31) == 0: n += 1
    return n

LUT = [
    0xF0F0F0F1, 0xE1E1E1E2, 0xD4EC4EC5, 0xC9C9C9CA,
    0xBFA02FE8, 0xB640B641, 0xAD83C2E0, 0xA57EB503,
    0x9E009E01, 0x96F96F97, 0x90653E22, 0x8A3968B4,
    0x8469EE59, 0x7EF388AE, 0x79D2263F, 0x75007501,
]

# Ideal midpoint LUT: LUT[k] = round(2^32 / (1 + (2k+1)/32))
LUT_MID = []
for k in range(16):
    d_mid = 1.0 + (2*k + 1) / 32.0
    val = round(2**32 / d_mid)
    if val > 0xFFFFFFFF:
        val = 0xFFFFFFFF
    LUT_MID.append(val)

def golden(x):
    if x == 0: return 0xFFFFFFFF
    return ((1 << 32) // x) & 0xFFFFFFFF

def nr_rtl_model(x, lut, use_fix=False):
    """Bit-accurate model of the RTL."""
    if x == 0:
        return 0xFFFFFFFF

    # Stage 1: CLZ + LUT
    lz = clz32(x)
    d_norm = (x << lz) & 0xFFFFFFFF  # Q1.31
    idx = (d_norm >> 27) & 0xF
    r0 = lut[idx]  # Q0.32

    # Stage 2: NR iter 1
    dr0 = d_norm * r0  # unsigned 64-bit product (Q1.63)
    if use_fix:
        dr0_q1_31 = (dr0 >> 32) & 0xFFFFFFFF  # FIXED
    else:
        dr0_q1_31 = (dr0 >> 31) & 0xFFFFFFFF  # BUG
    
    # RTL: corr1 = {1'b1, 32'h0} - {1'b0, dr0_q1_31}  (33-bit)
    corr1 = (1 << 32) - dr0_q1_31  # 33-bit result
    corr1_overflow = (corr1 >> 32) & 1
    corr1_low = corr1 & 0xFFFFFFFF

    # RTL: r1_full = s1_r0 * corr1[31:0]  (65-bit)
    r1_full = r0 * corr1_low
    
    if corr1_overflow:
        r1 = r0  # clamp
    else:
        r1 = (r1_full >> 31) & 0xFFFFFFFF  # [62:31] for Q0.32

    # Stage 3: NR iter 2
    dr1 = d_norm * r1
    if use_fix:
        dr1_q1_31 = (dr1 >> 32) & 0xFFFFFFFF  # FIXED
    else:
        dr1_q1_31 = (dr1 >> 31) & 0xFFFFFFFF  # BUG
    
    corr2 = (1 << 32) - dr1_q1_31
    corr2_overflow = (corr2 >> 32) & 1
    corr2_low = corr2 & 0xFFFFFFFF
    r2_full = r1 * corr2_low
    r2 = (r2_full >> 31) & 0xFFFFFFFF  # [62:31] for Q0.32

    # De-normalize
    if lz >= 31:
        result_wide = r2 << (lz - 31)
        if (result_wide >> 32) != 0:
            result = 0xFFFFFFFF  # overflow saturation
        else:
            result = result_wide & 0xFFFFFFFF
    else:
        result = r2 >> (31 - lz)
    
    return result & 0xFFFFFFFF

def within_tolerance(got, exp, tol):
    if exp == 0xFFFFFFFF:
        return got == exp
    return abs(int(got) - int(exp)) <= tol

# ─── Test all directed vectors ───
vectors = [0, 1<<16, 2<<16, 3<<16, (1<<16)//2, 0x00010000, 0x7FFFFFFF,
           1, 0x00000100, 0x00008000, 0x00100000, 0x80000000, 0xFFFFFFFF]

print("=" * 100)
print("DIRECTED TEST VECTORS")
print("=" * 100)
for lut_name, lut, fix in [("CUR+BUG", LUT, False), ("CUR+FIX", LUT, True), ("MID+FIX", LUT_MID, True)]:
    print(f"\n--- {lut_name} ---")
    print(f"{'x':>12} {'golden':>12} {'got':>12} {'err':>8} {'pass?':>6}")
    pass_count = 0
    for x in vectors:
        g = golden(x)
        got = nr_rtl_model(x, lut, use_fix=(fix))
        err = abs(int(g) - int(got)) if g != 0xFFFFFFFF else (0 if got == g else 999999)
        ok = within_tolerance(got, g, 2)
        if ok: pass_count += 1
        flag = "  OK" if ok else "FAIL"
        print(f"0x{x:08X} 0x{g:08X} 0x{got:08X} {err:8d} {flag}")
    print(f"  Pass: {pass_count}/{len(vectors)}")

# ─── Test random 500 ───
print("\n" + "=" * 100)
print("RANDOM 500 TEST")
print("=" * 100)
for lut_name, lut, fix in [("CUR+BUG", LUT, False), ("CUR+FIX", LUT, True), ("MID+FIX", LUT_MID, True)]:
    random.seed(20260306)
    pass_count = 0
    max_err = 0
    worst_x = 0
    fails = []
    for _ in range(500):
        x = random.randint(1, 0xFFFFFFFF)
        g = golden(x)
        got = nr_rtl_model(x, lut, use_fix=(fix))
        err = abs(int(g) - int(got))
        if within_tolerance(got, g, 2):
            pass_count += 1
        else:
            if len(fails) < 5:
                fails.append((x, g, got, err))
        if err > max_err:
            max_err = err
            worst_x = x
    print(f"{lut_name}: {pass_count}/500, max_err={max_err} at x=0x{worst_x:08X}")
    for x, g, got, err in fails:
        lz = clz32(x)
        print(f"  FAIL: x=0x{x:08X} lz={lz} golden=0x{g:08X} got=0x{got:08X} err={err}")

# ─── Additional: investigate what LUT precision is needed ───
print("\n" + "=" * 100)
print("LUT OPTIMIZATION: checking how many LUT entries needed for tol=2")
print("=" * 100)
for lut_bits in [4, 5, 6]:
    n_entries = 1 << lut_bits
    lut_opt = []
    for k in range(n_entries):
        d_mid = 1.0 + (2*k + 1) / (2*n_entries)
        val = round(2**32 / d_mid)
        if val > 0xFFFFFFFF: val = 0xFFFFFFFF
        lut_opt.append(val)
    
    # Test with this LUT
    random.seed(20260306)
    pass_count_random = 0
    max_err_random = 0
    for _ in range(500):
        x = random.randint(1, 0xFFFFFFFF)
        g = golden(x)
        lz = clz32(x)
        d_norm = (x << lz) & 0xFFFFFFFF
        idx = (d_norm >> (31 - lut_bits)) & ((1 << lut_bits) - 1)
        r0 = lut_opt[idx]
        
        # NR iter 1
        dr0 = d_norm * r0
        dr0_q1_31 = (dr0 >> 32) & 0xFFFFFFFF
        corr1 = ((1 << 32) - dr0_q1_31) & 0xFFFFFFFF
        r1 = (r0 * corr1 >> 31) & 0xFFFFFFFF
        
        # NR iter 2
        dr1 = d_norm * r1
        dr1_q1_31 = (dr1 >> 32) & 0xFFFFFFFF
        corr2 = ((1 << 32) - dr1_q1_31) & 0xFFFFFFFF
        r2 = (r1 * corr2 >> 31) & 0xFFFFFFFF
        
        if lz >= 31:
            result = r2 << (lz - 31)
            if (result >> 32): result = 0xFFFFFFFF
            result &= 0xFFFFFFFF
        else:
            result = r2 >> (31 - lz)
        
        err = abs(int(g) - int(result))
        if err <= 2: pass_count_random += 1
        if err > max_err_random: max_err_random = err
    
    # Test directed
    pass_count_directed = 0
    max_err_directed = 0
    for x in vectors:
        g = golden(x)
        if x == 0:
            result = 0xFFFFFFFF
        else:
            lz = clz32(x)
            d_norm = (x << lz) & 0xFFFFFFFF
            idx = (d_norm >> (31 - lut_bits)) & ((1 << lut_bits) - 1)
            r0 = lut_opt[idx]
            
            dr0 = d_norm * r0
            dr0_q1_31 = (dr0 >> 32) & 0xFFFFFFFF
            corr1 = ((1 << 32) - dr0_q1_31) & 0xFFFFFFFF
            r1 = (r0 * corr1 >> 31) & 0xFFFFFFFF
            
            dr1 = d_norm * r1
            dr1_q1_31 = (dr1 >> 32) & 0xFFFFFFFF
            corr2 = ((1 << 32) - dr1_q1_31) & 0xFFFFFFFF
            r2 = (r1 * corr2 >> 31) & 0xFFFFFFFF
            
            if lz >= 31:
                result = r2 << (lz - 31)
                if (result >> 32): result = 0xFFFFFFFF
                result &= 0xFFFFFFFF
            else:
                result = r2 >> (31 - lz)
        
        err = abs(int(g) - int(result)) if g != 0xFFFFFFFF else (0 if result == g else 999999)
        if within_tolerance(result, g, 2): pass_count_directed += 1
        if g != 0xFFFFFFFF and err > max_err_directed: max_err_directed = err
    
    print(f"LUT {lut_bits}-bit ({n_entries} entries): directed={pass_count_directed}/{len(vectors)}, random={pass_count_random}/500, max_err_d={max_err_directed}, max_err_r={max_err_random}")

# ─── Print midpoint LUT values for the 4-bit case ───
print("\n--- Midpoint LUT[16] values in Verilog format ---")
for k in range(16):
    d_mid = 1.0 + (2*k+1)/32.0
    val = round(2**32 / d_mid)
    if val > 0xFFFFFFFF: val = 0xFFFFFFFF
    print(f"  4'd{k:>2}: r0_lut = 32'h{val:08X};  // 1/{d_mid:.5f} = {val/2**32:.9f}")
