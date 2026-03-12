import ctypes
import struct


def bits_to_f32(bits: int) -> float:
    return struct.unpack(">f", struct.pack(">I", bits & 0xFFFFFFFF)
    )[0]


def f32_to_bits(value: float) -> int:
    return struct.unpack(">I", struct.pack(">f", ctypes.c_float(value).value))[0]


def rand_fp32_bits(rng, low: float, high: float) -> int:
    return f32_to_bits(rng.uniform(low, high))
