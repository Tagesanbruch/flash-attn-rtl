from dataclasses import dataclass
from typing import Dict, Tuple


@dataclass(frozen=True)
class TensorDesc:
    shape: Tuple[int, int]
    stride_bytes: int
    dtype: str

    def validate(self):
        if len(self.shape) != 2:
            raise ValueError(f"shape must be 2D, got {self.shape}")
        if self.dtype != "q8_8":
            raise ValueError(f"dtype must be q8_8 for baseline, got {self.dtype}")


class FlashAttnHostAPI:
    REG = {
        "CTRL": 0x00,
        "STATUS": 0x04,
        "CFG": 0x08,
        "Q_BASE_L": 0x14,
        "Q_BASE_H": 0x18,
        "K_BASE_L": 0x1C,
        "K_BASE_H": 0x20,
        "V_BASE_L": 0x24,
        "V_BASE_H": 0x28,
        "O_BASE_L": 0x2C,
        "O_BASE_H": 0x30,
        "STRIDE_BYTES": 0x34,
        "NEG_LARGE": 0x38,
        "SCALE": 0x3C,
    }

    def build_program(
        self,
        q: TensorDesc,
        k: TensorDesc,
        v: TensorDesc,
        o: TensorDesc,
        q_base: int,
        k_base: int,
        v_base: int,
        o_base: int,
        causal_en: bool = True,
        neg_large_q8_8: int = 0x8000,
        scale_q8_8: int = 0x0020,
    ) -> Dict[int, int]:
        for tensor in (q, k, v, o):
            tensor.validate()

        if not (q.shape == k.shape == v.shape == o.shape):
            raise ValueError("Q/K/V/O shapes must match baseline in this API")

        regs = {
            self.REG["CFG"]: 0x1 if causal_en else 0x0,
            self.REG["Q_BASE_L"]: q_base & 0xFFFFFFFF,
            self.REG["Q_BASE_H"]: (q_base >> 32) & 0xFFFFFFFF,
            self.REG["K_BASE_L"]: k_base & 0xFFFFFFFF,
            self.REG["K_BASE_H"]: (k_base >> 32) & 0xFFFFFFFF,
            self.REG["V_BASE_L"]: v_base & 0xFFFFFFFF,
            self.REG["V_BASE_H"]: (v_base >> 32) & 0xFFFFFFFF,
            self.REG["O_BASE_L"]: o_base & 0xFFFFFFFF,
            self.REG["O_BASE_H"]: (o_base >> 32) & 0xFFFFFFFF,
            self.REG["STRIDE_BYTES"]: q.stride_bytes,
            self.REG["NEG_LARGE"]: neg_large_q8_8 & 0xFFFF,
            self.REG["SCALE"]: scale_q8_8 & 0xFFFF,
            self.REG["CTRL"]: 0x1,
        }
        return regs
