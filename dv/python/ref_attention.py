import math
import numpy as np


def quant_q8_8(arr: np.ndarray) -> np.ndarray:
    scaled = np.round(arr * 256.0)
    clipped = np.clip(scaled, -32768, 32767)
    return clipped.astype(np.int16)


def dequant_q8_8(arr: np.ndarray) -> np.ndarray:
    return arr.astype(np.float32) / 256.0


def online_row_attention_q8_8(q: np.ndarray, k: np.ndarray, v: np.ndarray, causal: bool = True):
    s, d = q.shape
    out = np.zeros((s, d), dtype=np.float32)

    qf = dequant_q8_8(quant_q8_8(q))
    kf = dequant_q8_8(quant_q8_8(k))
    vf = dequant_q8_8(quant_q8_8(v))

    scale = 1.0 / math.sqrt(float(d))

    for i in range(s):
        m = -1e30
        l = 0.0
        acc = np.zeros((d,), dtype=np.float32)
        for j in range(s):
            score = float(np.dot(qf[i], kf[j]) * scale)
            if causal and j > i:
                score = -1e9

            m_new = max(m, score)
            alpha = math.exp(m - m_new) if m > -1e20 else 0.0
            p = math.exp(score - m_new)

            l = alpha * l + p
            acc = alpha * acc + p * vf[j]
            m = m_new

        if l != 0.0:
            out[i] = acc / l

    return out
