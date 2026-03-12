module fa_fp32_softmax_update_scalar (
  input  logic        i_row_start,
  input  logic [15:0] i_score_bf16,
  input  logic [15:0] i_value_bf16,
  input  logic [31:0] i_m_old_fp32,
  input  logic [31:0] i_l_old_fp32,
  input  logic [31:0] i_acc_old_fp32,
  output logic [31:0] o_m_new_fp32,
  output logic [31:0] o_l_new_fp32,
  output logic [31:0] o_acc_new_fp32,
  output logic [31:0] o_inv_l_new_fp32,
  output logic [31:0] o_exp_old_fp32,
  output logic [31:0] o_exp_new_fp32
);
  logic [31:0] score_fp32;
  logic [31:0] value_fp32;
  logic        score_gt_old;
  logic        score_lt_old;
  logic        score_eq_old;
  logic        score_unordered;
  logic [31:0] m_max_fp32;
  logic [31:0] m_new_fp32;
  logic [31:0] neg_m_new_fp32;
  logic [31:0] diff_old_fp32;
  logic [31:0] diff_new_fp32;
  logic [31:0] exp_old_core_fp32;
  logic [31:0] exp_new_core_fp32;
  logic [31:0] l_scaled_fp32;
  logic [31:0] acc_scaled_fp32;
  logic [31:0] value_term_fp32;

  fa_bf16_to_fp32 u_score_widen (
    .i_x_bf16(i_score_bf16),
    .o_y_fp32(score_fp32)
  );

  fa_bf16_to_fp32 u_value_widen (
    .i_x_bf16(i_value_bf16),
    .o_y_fp32(value_fp32)
  );

  fa_fp32_max_compare u_max (
    .i_a_fp32(score_fp32),
    .i_b_fp32(i_m_old_fp32),
    .o_a_gt_b(score_gt_old),
    .o_a_lt_b(score_lt_old),
    .o_a_eq_b(score_eq_old),
    .o_unordered(score_unordered),
    .o_max_fp32(m_max_fp32)
  );

  assign m_new_fp32 = i_row_start ? score_fp32 : m_max_fp32;
  assign neg_m_new_fp32 = {~m_new_fp32[31], m_new_fp32[30:0]};
  assign o_m_new_fp32 = m_new_fp32;

  fa_fp32_add u_diff_old (
    .i_a_fp32(i_m_old_fp32),
    .i_b_fp32(neg_m_new_fp32),
    .o_y_fp32(diff_old_fp32)
  );

  fa_fp32_add u_diff_new (
    .i_a_fp32(score_fp32),
    .i_b_fp32(neg_m_new_fp32),
    .o_y_fp32(diff_new_fp32)
  );

  fa_fp32_exp2_pwl u_exp_old (
    .i_x_fp32(diff_old_fp32),
    .o_y_fp32(exp_old_core_fp32)
  );

  fa_fp32_exp2_pwl u_exp_new (
    .i_x_fp32(diff_new_fp32),
    .o_y_fp32(exp_new_core_fp32)
  );

  assign o_exp_old_fp32 = i_row_start ? 32'd0 : exp_old_core_fp32;
  assign o_exp_new_fp32 = i_row_start ? 32'h3F80_0000 : exp_new_core_fp32;

  fa_fp32_mul_q16 u_l_scaled (
    .i_a_fp32(i_l_old_fp32),
    .i_b_fp32(o_exp_old_fp32),
    .o_y_fp32(l_scaled_fp32)
  );

  fa_fp32_mul_q16 u_acc_scaled (
    .i_a_fp32(i_acc_old_fp32),
    .i_b_fp32(o_exp_old_fp32),
    .o_y_fp32(acc_scaled_fp32)
  );

  fa_fp32_mul_q16 u_value_term (
    .i_a_fp32(value_fp32),
    .i_b_fp32(o_exp_new_fp32),
    .o_y_fp32(value_term_fp32)
  );

  fa_fp32_add u_l_new (
    .i_a_fp32(i_row_start ? 32'd0 : l_scaled_fp32),
    .i_b_fp32(o_exp_new_fp32),
    .o_y_fp32(o_l_new_fp32)
  );

  fa_fp32_add u_acc_new (
    .i_a_fp32(i_row_start ? 32'd0 : acc_scaled_fp32),
    .i_b_fp32(i_row_start ? value_fp32 : value_term_fp32),
    .o_y_fp32(o_acc_new_fp32)
  );

  fa_fp32_recip u_inv_l (
    .i_x_fp32(o_l_new_fp32),
    .o_y_fp32(o_inv_l_new_fp32)
  );
endmodule
