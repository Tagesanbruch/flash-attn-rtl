#!/usr/bin/env python3
"""Generate 32-entry midpoint LUT and verify full algorithm."""
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

# Generate 32-entry midpoint LUT
LUT32 = []
print("// 32-entry midpoint LUT: r0 = round(2^32 / d_mid)")
print("// d_mid = 1 + (2k+1)/64 for segment k")
for k in range(32):
    d_mid = 1.0 + (2*k + 1) / 64.0
    val = round(2**32 / d_mid)
    if val > 0xFFFFFFFF: val = 0xFFFFFFFF
    LUT32.append(val)
    print(f"      5'd{k:>2}: r0_lut = 32'h{val >> 16:04X}_{val & 0xFFFF:04X};  // 1/{d_mid:.6f}")

def golden(x):
    if x == 0: return 0xFFFFFFFF
    return ((1 << 32) // x) & 0xFFFFFFFF

def nr_model_32(x):
    """Model with 32-entry midpoint LUT + bit-slicing fix + x=1 handling."""
    if x == 0: return 0xFFFFFFFF
    if x == 1: return 0  # overflow match

    lz = clz32(x)
    d_norm = (x << lz) & 0xFFFFFFFF
    idx = (d_norm >> 26) & 0x1F  # 5-bit index
    r0 = LUT32[idx]

    # NR iter 1 (FIXED)
    dr0 = d_norm * r0
    dr0_q1_31 = (dr0 >> 32) & 0xFFFFFFFF
    corr1 = (1 << 32) - dr0_q1_31
    corr1_bit32 = (corr1 >> 32) & 1
    corr1_low = corr1 & 0xFFFFFFFF
    r1_full = r0 * corr1_low
    r1 = r0 if corr1_bit32 else ((r1_full >> 31) & 0xFFFFFFFF)

    # NR iter 2 (FIXED)
    dr1 = d_norm * r1
    dr1_q1_31 = (dr1 >> 32) & 0xFFFFFFFF
    corr2 = (1 << 32) - dr1_q1_31
    corr2_bit32 = (corr2 >> 32) & 1
    corr2_low = corr2 & 0xFFFFFFFF
    r2_full = r1 * corr2_low
    r2 = r1 if corr2_bit32 else ((r2_full >> 31) & 0xFFFFFFFF)

    # De-normalize
    if lz >= 31:
        result_wide = r2 << (lz - 31)
        if (result_wide >> 32) != 0:
            result = 0xFFFFFFFF
        else:
            result = result_wide & 0xFFFFFFFF
    else:
        result = r2 >> (31 - lz)
    return result & 0xFFFFFFFF

def within_tolerance(got, exp, tol):
    if exp == 0xFFFFFFFF:
        return got == exp
    return abs(int(got) - int(exp)) <= tol

# Directed test
vectors = [0, 1<<16, 2<<16, 3<<16, (1<<16)//2, 0x00010000, 0x7FFFFFFF,
           1, 0x00000100, 0x00008000, 0x00100000, 0x80000000, 0xFFFFFFFF]

print("\n--- Directed test (32-entry LUT + fix + x=1 handling) ---")
all_pass = True
for x in vectors:
    g = golden(x)
    got = nr_model_32(x)
    err = abs(int(g) - int(got)) if g != 0xFFFFFFFF else (0 if got == g else 999999)
    ok = within_tolerance(got, g, 2)
    if not ok: all_pass = False
    flag = "  OK" if ok else "FAIL"
    print(f"  x=0x{x:08X} golden=0x{g:08X} got=0x{got:08X} err={err:>8d} {flag}")
print(f"  Directed: {'ALL PASS' if all_pass else 'SOME FAIL'}")

# Random 500 test
random.seed(20260306)
pass_count = 0
max_err = 0
for _ in range(500):
    x = random.randint(1, 0xFFFFFFFF)
    g = golden(x)
    got = nr_model_32(x)
    err = abs(int(g) - int(got))
    if within_tolerance(got, g, 2): pass_count += 1
    if err > max_err: max_err = err
print(f"\n  Random 500: {pass_count}/500, max_err={max_err}")

# Pipeline 20 test
random.seed(20260307)
pass_count = 0
for _ in range(20):
    x = random.randint(1, 0xFFFFFFFF)
    g = golden(x)
    got = nr_model_32(x)
    if within_tolerance(got, g, 2): pass_count += 1
print(f"  Pipeline 20: {pass_count}/20")

# Exhaustive stress: 100k random
random.seed(42)
pass_count = 0
max_err = 0
worst_x = 0
for _ in range(100000):
    x = random.randint(1, 0xFFFFFFFF)
    g = golden(x)
    got = nr_model_32(x)
    err = abs(int(g) - int(got))
    if within_tolerance(got, g, 2): pass_count += 1
    if err > max_err:
        max_err = err
        worst_x = x
print(f"  Stress 100k: {pass_count}/100000, max_err={max_err} at x=0x{worst_x:08X}")
