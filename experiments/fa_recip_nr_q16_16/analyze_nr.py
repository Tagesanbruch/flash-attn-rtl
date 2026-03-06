#!/usr/bin/env python3
"""Analyze the Newton-Raphson reciprocal algorithm and verify fixes."""

def clz32(val):
    if val == 0: return 32
    n = 0
    v = val & 0xFFFFFFFF
    if (v >> 16) == 0: n += 16; v <<= 16
    if (v >> 24) == 0: n += 8; v <<= 8
    if (v >> 28) == 0: n += 4; v <<= 4
    if (v >> 30) == 0: n += 2; v <<= 2
    if (v >> 31) == 0: n += 1
    return n

# Current LUT
LUT = [
    0xF0F0F0F1, 0xE1E1E1E2, 0xD4EC4EC5, 0xC9C9C9CA,
    0xBFA02FE8, 0xB640B641, 0xAD83C2E0, 0xA57EB503,
    0x9E009E01, 0x96F96F97, 0x90653E22, 0x8A3968B4,
    0x8469EE59, 0x7EF388AE, 0x79D2263F, 0x75007501,
]

def golden_recip(x):
    if x == 0: return 0xFFFFFFFF
    return ((1 << 32) // x) & 0xFFFFFFFF

def nr_recip_buggy(x):
    """Current (buggy) implementation."""
    if x == 0: return 0xFFFFFFFF
    lz = clz32(x)
    d_norm = (x << lz) & 0xFFFFFFFF  # Q1.31
    idx = (d_norm >> 27) & 0xF
    r0 = LUT[idx]  # Q0.32
    
    # Stage 2: NR iter 1
    dr0 = d_norm * r0  # Q1.63
    dr0_q1_31 = (dr0 >> 31) & 0xFFFFFFFF  # BUG: should be >> 32
    two_minus_dr0 = (0xFFFFFFFF - dr0_q1_31) & 0xFFFFFFFF  # ~dr0
    r1_full = r0 * two_minus_dr0  # Q1.63
    r1 = (r1_full >> 31) & 0xFFFFFFFF  # This extracts Q0.32
    
    # Stage 3: NR iter 2
    dr1 = d_norm * r1  # Q1.63
    dr1_q1_31 = (dr1 >> 31) & 0xFFFFFFFF  # BUG: should be >> 32
    two_minus_dr1 = (0xFFFFFFFF - dr1_q1_31) & 0xFFFFFFFF
    r2_full = r1 * two_minus_dr1
    r2 = (r2_full >> 31) & 0xFFFFFFFF
    
    # De-normalize
    shift = 31 - lz
    if shift >= 0:
        result = r2 >> shift
    else:
        result = (r2 << (-shift)) & 0xFFFFFFFF
    return result & 0xFFFFFFFF

def nr_recip_fixed(x):
    """Fixed implementation."""
    if x == 0: return 0xFFFFFFFF
    lz = clz32(x)
    d_norm = (x << lz) & 0xFFFFFFFF  # Q1.31
    idx = (d_norm >> 27) & 0xF
    r0 = LUT[idx]  # Q0.32
    
    # Stage 2: NR iter 1
    dr0 = d_norm * r0  # Q1.63
    dr0_q1_31 = (dr0 >> 32) & 0xFFFFFFFF  # FIX: >> 32
    two_minus_dr0 = (0xFFFFFFFF - dr0_q1_31) & 0xFFFFFFFF
    r1_full = r0 * two_minus_dr0  # Q1.63
    r1 = (r1_full >> 31) & 0xFFFFFFFF  # Q0.32 extraction OK
    
    # Stage 3: NR iter 2
    dr1 = d_norm * r1  # Q1.63
    dr1_q1_31 = (dr1 >> 32) & 0xFFFFFFFF  # FIX: >> 32
    two_minus_dr1 = (0xFFFFFFFF - dr1_q1_31) & 0xFFFFFFFF
    r2_full = r1 * two_minus_dr1
    r2 = (r2_full >> 31) & 0xFFFFFFFF
    
    # De-normalize
    shift = 31 - lz
    if shift >= 0:
        result = r2 >> shift
    else:
        result = (r2 << (-shift)) & 0xFFFFFFFF
    return result & 0xFFFFFFFF

# === BUG DEMO ===
print("=" * 70)
print("BUG DEMONSTRATION: dr0[62:31] vs dr0[63:32]")
print("=" * 70)
d_norm = 0x80000000  # d_real = 1.0
r0 = 0xF0F0F0F1     # r0_real ≈ 0.94118
dr0 = d_norm * r0
print(f"d_norm=0x{d_norm:08X} r0=0x{r0:08X} dr0=0x{dr0:016X}")
print(f"  dr0[62:31] (buggy)  = 0x{(dr0>>31)&0xFFFFFFFF:08X} = {(dr0>>31)&0xFFFFFFFF:>10d}/2^31 = {((dr0>>31)&0xFFFFFFFF)/2**31:.6f}")
print(f"  dr0[63:32] (fixed)  = 0x{(dr0>>32)&0xFFFFFFFF:08X} = {(dr0>>32)&0xFFFFFFFF:>10d}/2^31 = {((dr0>>32)&0xFFFFFFFF)/2**31:.6f}")
print(f"  Expected d*r        = {1.0 * r0/2**32:.6f}")

# === LUT comparison ===
print("\n" + "=" * 70)
print("LUT ANALYSIS")
print("=" * 70)
print(f"{'k':>2} {'d_range':>18} {'Ideal(mid)':>12} {'Current':>12} {'Rel Err%':>9}")
for k in range(16):
    d_lo = 1.0 + k/16.0
    d_hi = 1.0 + (k+1)/16.0
    d_mid = (d_lo + d_hi) / 2.0
    ideal = round(2**32 / d_mid)
    if ideal > 0xFFFFFFFF: ideal = 0xFFFFFFFF
    cur = LUT[k]
    cur_real = cur / 2**32
    ideal_real = 1.0 / d_mid
    rel_err = abs(cur_real - ideal_real) / ideal_real * 100
    print(f"{k:2d} [{d_lo:.3f},{d_hi:.3f}) 0x{ideal:08X} 0x{cur:08X} {rel_err:.3f}%")

# === r extraction analysis ===
print("\n" + "=" * 70)
print("r EXTRACTION: r1_full[62:31] for Q0.32")
print("=" * 70)
print("When r0 * (2-d*r0) is computed, the result is in Q0.32 * Q1.31 = Q1.63")
print("Since 2-d*r ≈ 1.x and r < 1.0, the product r_new < 1.0")
print("So bit 63 = 0, and we need bits [62:31] for the Q0.32 result")
print("This extraction IS correct in the current code!")

# === Functional verification ===
print("\n" + "=" * 70)
print("FUNCTIONAL VERIFICATION")
print("=" * 70)
test_values = [0x00010000, 0x00020000, 0x00030000, 0x00008000,
               0x00040000, 0x00100000, 0x00000001, 0x7FFFFFFF, 0xFFFFFFFF]
labels = ["1.0", "2.0", "3.0", "0.5", "4.0", "16.0", "min", "~32768", "max"]

print(f"{'x':>12} {'label':>8} {'golden':>12} {'buggy':>12} {'fixed':>12} {'err_b':>8} {'err_f':>8}")
for x, lbl in zip(test_values, labels):
    g = golden_recip(x)
    b = nr_recip_buggy(x)
    f = nr_recip_fixed(x)
    eb = abs(int(g) - int(b))
    ef = abs(int(g) - int(f))
    print(f"0x{x:08X} {lbl:>8} 0x{g:08X} 0x{b:08X} 0x{f:08X} {eb:>8d} {ef:>8d}")

# === Sweep test with tolerance ===
print("\n" + "=" * 70)
print("SWEEP TEST (500 random values, tol=2)")
print("=" * 70)
import random
random.seed(20260306)
pass_buggy = 0
pass_fixed = 0
max_err_fixed = 0
worst_x_fixed = 0
for _ in range(500):
    x = random.randint(1, 0xFFFFFFFF)
    g = golden_recip(x)
    b = nr_recip_buggy(x)
    f = nr_recip_fixed(x)
    if abs(int(g) - int(b)) <= 2: pass_buggy += 1
    ef = abs(int(g) - int(f))
    if ef <= 2: pass_fixed += 1
    if ef > max_err_fixed:
        max_err_fixed = ef
        worst_x_fixed = x

print(f"Buggy: {pass_buggy}/500 pass (tol=2)")
print(f"Fixed: {pass_fixed}/500 pass (tol=2)")
print(f"Fixed max error: {max_err_fixed} LSB at x=0x{worst_x_fixed:08X}")

if pass_fixed < 500:
    print("\n--- Fixed version still has failures! Need to investigate ---")
    # Show some failures
    random.seed(20260306)
    fail_count = 0
    for _ in range(500):
        x = random.randint(1, 0xFFFFFFFF)
        g = golden_recip(x)
        f = nr_recip_fixed(x)
        ef = abs(int(g) - int(f))
        if ef > 2 and fail_count < 10:
            lz = clz32(x)
            print(f"  FAIL: x=0x{x:08X} lz={lz} golden=0x{g:08X} fixed=0x{f:08X} err={ef}")
            fail_count += 1
