from __future__ import annotations

from ctypes import CDLL, c_uint16, c_uint32
from pathlib import Path


_LIB_PATH = Path(__file__).resolve().parents[3] / "cmodel" / "build" / "libbf16_cmodel.so"

if not _LIB_PATH.exists():
    raise FileNotFoundError(
        f"cmodel shared library not found: {_LIB_PATH}. Run `make -C cmodel build`."
    )

_LIB = CDLL(str(_LIB_PATH))

_LIB.cmodel_fp32_add.argtypes = [c_uint32, c_uint32]
_LIB.cmodel_fp32_add.restype = c_uint32
_LIB.cmodel_fp32_mul_q16.argtypes = [c_uint32, c_uint32]
_LIB.cmodel_fp32_mul_q16.restype = c_uint32
_LIB.cmodel_fp32_exp2_pwl.argtypes = [c_uint32]
_LIB.cmodel_fp32_exp2_pwl.restype = c_uint32
_LIB.cmodel_fp32_recip.argtypes = [c_uint32]
_LIB.cmodel_fp32_recip.restype = c_uint32
_LIB.cmodel_fp32_to_bf16.argtypes = [c_uint32]
_LIB.cmodel_fp32_to_bf16.restype = c_uint16
_LIB.cmodel_bf16_to_fp32.argtypes = [c_uint16]
_LIB.cmodel_bf16_to_fp32.restype = c_uint32


def fp32_add(a_bits: int, b_bits: int) -> int:
    return int(_LIB.cmodel_fp32_add(c_uint32(a_bits), c_uint32(b_bits)))


def fp32_mul_q16(a_bits: int, b_bits: int) -> int:
    return int(_LIB.cmodel_fp32_mul_q16(c_uint32(a_bits), c_uint32(b_bits)))


def fp32_exp2_pwl(x_bits: int) -> int:
    return int(_LIB.cmodel_fp32_exp2_pwl(c_uint32(x_bits)))


def fp32_recip(x_bits: int) -> int:
    return int(_LIB.cmodel_fp32_recip(c_uint32(x_bits)))


def fp32_to_bf16(x_bits: int) -> int:
    return int(_LIB.cmodel_fp32_to_bf16(c_uint32(x_bits)))


def bf16_to_fp32(x_bits: int) -> int:
    return int(_LIB.cmodel_bf16_to_fp32(c_uint16(x_bits)))
