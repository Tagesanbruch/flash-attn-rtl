module fa_bf16_mul_lane (
  input  logic [15:0] i_a_bf16,
  input  logic [15:0] i_b_bf16,
  output logic [31:0] o_y_fp32,
  output logic [15:0] o_y_bf16
);
  logic        sign;
  logic signed [10:0] exp_unbiased;
  logic [15:0] mant_prod;
  logic        is_zero;
  logic        is_inf;
  logic        is_nan;
  logic        a_subnorm;
  logic        b_subnorm;

  fa_bf16_mul_prealign u_prealign (
    .i_a_bf16(i_a_bf16),
    .i_b_bf16(i_b_bf16),
    .o_sign(sign),
    .o_exp_unbiased(exp_unbiased),
    .o_mant_prod(mant_prod),
    .o_is_zero(is_zero),
    .o_is_inf(is_inf),
    .o_is_nan(is_nan),
    .o_a_subnorm(a_subnorm),
    .o_b_subnorm(b_subnorm)
  );

  fa_bf16_mul_norm_fp32 u_norm (
    .i_sign(sign),
    .i_exp_unbiased(exp_unbiased),
    .i_mant_prod(mant_prod),
    .i_is_zero(is_zero),
    .i_is_inf(is_inf),
    .i_is_nan(is_nan),
    .o_y_fp32(o_y_fp32)
  );

  fa_fp32_to_bf16 u_downcast (
    .i_x_fp32(o_y_fp32),
    .o_y_bf16(o_y_bf16)
  );
endmodule
