module fa_fp32_softmax_row (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        i_valid,
  input  logic        i_row_start,
  input  logic        i_row_end,
  input  logic [15:0] i_score_bf16,
  input  logic [15:0] i_value_bf16,
  output logic        o_valid,
  output logic        o_row_done,
  output logic [31:0] o_m_fp32,
  output logic [31:0] o_l_fp32,
  output logic [31:0] o_acc_fp32,
  output logic [31:0] o_inv_l_fp32,
  output logic [31:0] o_exp_old_fp32,
  output logic [31:0] o_exp_new_fp32
);
  logic [31:0] m_state_fp32;
  logic [31:0] l_state_fp32;
  logic [31:0] acc_state_fp32;

  logic [31:0] m_next_fp32;
  logic [31:0] l_next_fp32;
  logic [31:0] acc_next_fp32;
  logic [31:0] inv_l_next_fp32;
  logic [31:0] exp_old_next_fp32;
  logic [31:0] exp_new_next_fp32;

  fa_fp32_softmax_update_scalar u_scalar (
    .i_row_start(i_row_start),
    .i_score_bf16(i_score_bf16),
    .i_value_bf16(i_value_bf16),
    .i_m_old_fp32(m_state_fp32),
    .i_l_old_fp32(l_state_fp32),
    .i_acc_old_fp32(acc_state_fp32),
    .o_m_new_fp32(m_next_fp32),
    .o_l_new_fp32(l_next_fp32),
    .o_acc_new_fp32(acc_next_fp32),
    .o_inv_l_new_fp32(inv_l_next_fp32),
    .o_exp_old_fp32(exp_old_next_fp32),
    .o_exp_new_fp32(exp_new_next_fp32)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_state_fp32 <= 32'd0;
      l_state_fp32 <= 32'd0;
      acc_state_fp32 <= 32'd0;
      o_valid <= 1'b0;
      o_row_done <= 1'b0;
      o_m_fp32 <= 32'd0;
      o_l_fp32 <= 32'd0;
      o_acc_fp32 <= 32'd0;
      o_inv_l_fp32 <= 32'd0;
      o_exp_old_fp32 <= 32'd0;
      o_exp_new_fp32 <= 32'd0;
    end else begin
      o_valid <= i_valid;
      o_row_done <= i_valid && i_row_end;
      if (i_valid) begin
        m_state_fp32 <= m_next_fp32;
        l_state_fp32 <= l_next_fp32;
        acc_state_fp32 <= acc_next_fp32;
        o_m_fp32 <= m_next_fp32;
        o_l_fp32 <= l_next_fp32;
        o_acc_fp32 <= acc_next_fp32;
        o_inv_l_fp32 <= inv_l_next_fp32;
        o_exp_old_fp32 <= exp_old_next_fp32;
        o_exp_new_fp32 <= exp_new_next_fp32;
      end
    end
  end
endmodule
