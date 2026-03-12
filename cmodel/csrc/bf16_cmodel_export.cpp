#include "attention_core.hpp"

extern "C" {

uint32_t cmodel_fp32_add(uint32_t a_bits, uint32_t b_bits) {
    return attn::fp32_add_rtl_bits(a_bits, b_bits);
}

uint32_t cmodel_fp32_mul_q16(uint32_t a_bits, uint32_t b_bits) {
    return attn::fp32_mul_q16_bits(a_bits, b_bits);
}

uint32_t cmodel_fp32_exp2_pwl(uint32_t x_bits) {
    return attn::fp32_exp2_pwl_bits(x_bits);
}

uint32_t cmodel_fp32_recip(uint32_t x_bits) {
    return attn::fp32_recip_bits(x_bits);
}

uint16_t cmodel_fp32_to_bf16(uint32_t x_bits) {
    return attn::fp32_to_bf16_bits(x_bits);
}

uint32_t cmodel_bf16_to_fp32(uint16_t x_bits) {
    return attn::bf16_to_fp32_bits(x_bits);
}

} // extern "C"
