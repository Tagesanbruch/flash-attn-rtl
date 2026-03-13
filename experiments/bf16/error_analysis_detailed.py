#!/usr/bin/env python3
"""
Detailed BF16 Module Error Analysis with Numerical Comparisons
"""

import random
import struct
from typing import Tuple

def fp32_bits_to_float(bits: int) -> float:
    """Convert 32-bit integer representing IEEE 754 to Python float."""
    return struct.unpack('!f', struct.pack('!I', bits & 0xFFFFFFFF))[0]

def float_to_fp32_bits(f: float) -> int:
    """Convert Python float to 32-bit IEEE 754 representation."""
    return struct.unpack('!I', struct.pack('!f', f))[0]

def bf16_to_float(bf16_bits: int) -> float:
    """Convert BF16 bits to equivalent float value."""
    # BF16: 1 sign + 8 exp + 7 mantissa = 16 bits
    # Extend to FP32 by adding 16 zero bits to mantissa
    fp32_bits = (bf16_bits & 0xFFFF) << 16
    return fp32_bits_to_float(fp32_bits)

def analyze_arithmetic_errors(rtl_values, cmodel_values, num_format="fp32"):
    """Compute detailed error statistics for arithmetic operations.""" 
    if len(rtl_values) != len(cmodel_values):
        raise ValueError("RTL and cmodel value lists must have same length")
    
    errors = []
    mismatches = 0
    
    for rtl_bits, cmodel_bits in zip(rtl_values, cmodel_values):
        if rtl_bits != cmodel_bits:
            mismatches += 1
            
        if num_format == "fp32":
            rtl_float = fp32_bits_to_float(rtl_bits)
            cmodel_float = fp32_bits_to_float(cmodel_bits)
            error = abs(rtl_float - cmodel_float)
            errors.append(error)
        elif num_format == "bf16": 
            rtl_float = bf16_to_float(rtl_bits)
            cmodel_float = bf16_to_float(cmodel_bits)
            error = abs(rtl_float - cmodel_float)
            errors.append(error)
        else:
            # For conversion operations, track bit-level differences
            errors.append(0 if rtl_bits == cmodel_bits else 1)
    
    mae = sum(errors) / len(errors) if errors else 0
    max_error = max(errors) if errors else 0
    
    return {
        'samples': len(rtl_values),
        'mismatches': mismatches,
        'mae': mae,
        'max_error': max_error,
        'errors': errors
    }

def main():
    """Run detailed error analysis on all BF16 modules."""
    from cmodel_ref import (
        fp32_add, fp32_mul_q16, fp32_exp2_pwl, 
        fp32_recip, fp32_to_bf16, bf16_to_fp32
    )
    
    print("BF16 Module Detailed Error Analysis")
    print("=" * 50)
    
    rng = random.Random(20260312)
    samples = 2000
    
    # Test data generation
    test_values_fp32 = [
        float_to_fp32_bits(rng.uniform(-16.0, 16.0)) for _ in range(samples)
    ]
    test_pairs_fp32 = [
        (float_to_fp32_bits(rng.uniform(-16.0, 16.0)), 
         float_to_fp32_bits(rng.uniform(-16.0, 16.0))) 
        for _ in range(samples)
    ]
    test_values_bf16 = [
        fp32_to_bf16(val) for val in test_values_fp32
    ]
    
    print(f"Generated {samples} test vectors\n")
    
    # Module tests would go here - this is a framework
    print("Framework ready for module error analysis")
    print("Individual module tests should call analyze_arithmetic_errors()")

if __name__ == "__main__": 
    main()