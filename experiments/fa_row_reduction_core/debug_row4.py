#!/usr/bin/env python3
"""Debug row_reduction_core Row 4 failure."""
import random
import sys
sys.path.insert(0, '/Volumes/disk/work/flashattn/dv/cocotb/tests')
from fp_ref import online_softmax_step, recip_q16_16, to_s16, to_s32, to_u32

def row_reduction_ref(scores, values):
    m_reg = -32768
    l_reg = 0
    acc_reg = 0
    for s, v in zip(scores, values):
        m_reg, l_reg, acc_reg = online_softmax_step(m_reg, l_reg, acc_reg, s, v)
    recip = recip_q16_16(l_reg)
    norm_full = to_s32(acc_reg) * recip
    norm_shifted = norm_full >> 16
    result = norm_shifted & 0xFFFFFFFF
    result_s32 = to_s32(result)
    if result_s32 > 32767:
        return 32767
    elif result_s32 < -32768:
        return -32768
    else:
        return to_s16(result_s32)

random.seed(20260306)
for row_idx in range(5):
    row_len = random.randint(4, 16)
    scores = [random.randint(-2048, 2048) for _ in range(row_len)]
    values = [random.randint(-2048, 2048) for _ in range(row_len)]

    ref = row_reduction_ref(scores, values)
    print(f"\nRow {row_idx}: len={row_len}, ref={ref}")
    if row_idx == 4:
        print(f"  scores: {scores}")
        print(f"  values: {values}")

        # Step through online softmax
        m_reg = -32768
        l_reg = 0
        acc_reg = 0
        for i, (s, v) in enumerate(zip(scores, values)):
            m_reg, l_reg, acc_reg = online_softmax_step(m_reg, l_reg, acc_reg, s, v)
            print(f"  step {i}: s={s} v={v} -> m={m_reg} l=0x{to_u32(l_reg):08X}({l_reg}) acc=0x{to_u32(acc_reg):08X}({acc_reg})")

        print(f"\n  Final: l=0x{to_u32(l_reg):08X} ({l_reg}), acc=0x{to_u32(acc_reg):08X} ({acc_reg})")
        recip = recip_q16_16(l_reg)
        print(f"  recip_q16_16(l) = 0x{recip:08X} ({recip})")

        # Trace the multiplication
        acc_s32 = to_s32(acc_reg)
        print(f"  to_s32(acc) = {acc_s32} (0x{acc_s32 & 0xFFFFFFFF:08X})")
        norm_full = acc_s32 * recip
        print(f"  norm_full = acc * recip = {norm_full} (0x{norm_full & 0xFFFFFFFFFFFFFFFF:016X})")
        norm_shifted = norm_full >> 16
        print(f"  norm_shifted = norm_full >> 16 = {norm_shifted} (0x{norm_shifted & 0xFFFFFFFFFFFFFFFF:016X})")
        result = norm_shifted & 0xFFFFFFFF
        print(f"  result = norm_shifted & 0xFFFFFFFF = 0x{result:08X}")
        result_s32 = to_s32(result)
        print(f"  result_s32 = to_s32(result) = {result_s32}")
        if result_s32 > 32767:
            print(f"  -> SATURATE to 32767")
        elif result_s32 < -32768:
            print(f"  -> SATURATE to -32768")
        else:
            print(f"  -> output = to_s16({result_s32}) = {to_s16(result_s32)}")

        # What the RTL sees (Verilog arithmetic)
        print(f"\n  === RTL model ===")
        # acc_delay[2] is signed 32-bit
        acc_rtl = acc_reg & 0xFFFFFFFF
        recip_rtl = recip
        # $signed({1'b0, recip}): 33-bit signed, value = recip
        recip_signed = recip  # positive since MSB is 0
        # Multiply: 32-bit signed * 33-bit signed = 65-bit signed
        acc_signed = acc_s32
        product_65 = acc_signed * recip_signed
        print(f"  acc_signed={acc_signed}, recip={recip_signed}")
        print(f"  product_65 = {product_65} (0x{product_65 & 0xFFFFFFFFFFFFFFFF:016X})")
        # Truncated to 64-bit signed
        if product_65 >= (1 << 63):
            product_64 = product_65 - (1 << 64)
        elif product_65 < -(1 << 63):
            product_64 = product_65 + (1 << 64)
        else:
            product_64 = product_65
        print(f"  product_64 (truncated) = {product_64} (0x{product_64 & 0xFFFFFFFFFFFFFFFF:016X})")
        # >>> 16
        shifted = product_64 >> 16  # Python arithmetic shift preserves sign
        print(f"  shifted = product_64 >> 16 = {shifted}")
        # Check saturation
        if shifted > 32767:
            out = 32767
        elif shifted < -32768:
            out = -32768
        else:
            out = shifted & 0xFFFF
            if out >= 32768: out -= 65536
        print(f"  RTL output (with fix) = {out}")
