import random

from bf16.common.golden_models import (
    bf16_to_fp32_bits,
    calc_abs_error_stats,
    dotprod_fp32_reference,
    dotprod_mixed_reference,
    f32_to_bits,
    online_softmax_fp32_step,
    online_softmax_mixed_step,
    fp32_to_bf16_bits,
)


def check_dotprod() -> None:
    random.seed(20260312)
    for _ in range(200):
        n = random.randint(1, 32)
        a_vec = [fp32_to_bf16_bits(f32_to_bits(random.uniform(-4.0, 4.0))) for _ in range(n)]
        b_vec = [fp32_to_bf16_bits(f32_to_bits(random.uniform(-4.0, 4.0))) for _ in range(n)]
        fp32_ref = dotprod_fp32_reference(a_vec, b_vec)
        mixed_ref = dotprod_mixed_reference(a_vec, b_vec)
        assert len(fp32_ref["acc_fp32"]) == n
        assert len(mixed_ref["acc_stage_bf16"]) == n
        for stage_bf16, stage_fp32 in zip(mixed_ref["acc_stage_bf16"], mixed_ref["acc_stage_fp32"]):
            assert bf16_to_fp32_bits(stage_bf16) == stage_fp32

    stats = calc_abs_error_stats(fp32_ref["acc_fp32"], mixed_ref["acc_stage_fp32"])
    print(f"[golden] dotprod final MAE={stats['mae']:.6g} MAXE={stats['maxe']:.6g}")


def check_softmax_scalar() -> None:
    random.seed(20260312)
    for _ in range(500):
        steps = random.randint(1, 16)
        m_fp32 = 0
        l_fp32 = 0
        acc_fp32 = 0
        m_mixed = 0
        l_mixed = 0
        acc_mixed = 0
        for idx in range(steps):
            score = random.randint(0, 0xFFFF)
            value = random.randint(0, 0xFFFF)
            row_start = idx == 0
            fp32_state = online_softmax_fp32_step(m_fp32, l_fp32, acc_fp32, score, value, row_start)
            mixed_state = online_softmax_mixed_step(m_mixed, l_mixed, acc_mixed, score, value, row_start)
            m_fp32 = fp32_state["m_new_bits"]
            l_fp32 = fp32_state["l_new_bits"]
            acc_fp32 = fp32_state["acc_new_bits"]
            m_mixed = mixed_state["m_stage_fp32"]
            l_mixed = mixed_state["l_stage_fp32"]
            acc_mixed = mixed_state["acc_stage_fp32"]

    stats_l = calc_abs_error_stats([l_fp32], [l_mixed])
    stats_acc = calc_abs_error_stats([acc_fp32], [acc_mixed])
    print(f"[golden] softmax-scalar final l MAE={stats_l['mae']:.6g} acc MAE={stats_acc['mae']:.6g}")


if __name__ == "__main__":
    check_dotprod()
    check_softmax_scalar()
    print("[golden] shared golden models check passed")
