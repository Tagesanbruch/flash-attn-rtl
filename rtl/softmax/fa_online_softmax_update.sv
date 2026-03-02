module fa_online_softmax_update (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                i_row_start,
  input  logic                i_valid,
  input  logic                i_row_end,
  input  logic signed [15:0]  i_score_q8_8,
  input  logic signed [15:0]  i_value_q8_8,
  output logic signed [15:0]  o_m_q8_8,
  output logic        [31:0]  o_l_q16_16,
  output logic signed [31:0]  o_acc_q16_16,
  output logic                o_row_done
);
  logic signed [15:0] m_reg;
  logic [31:0] l_reg;
  logic signed [31:0] acc_reg;

  logic signed [15:0] m_new;
  logic signed [15:0] diff_old_q8_8;
  logic signed [15:0] diff_new_q8_8;
  logic [15:0] exp_old_q1_15;
  logic [15:0] exp_new_q1_15;

  logic [63:0] l_scaled_q32_31;
  logic [31:0] l_scaled_q16_16;
  logic [31:0] l_term_q16_16;
  logic [31:0] l_new_q16_16;

  logic signed [63:0] acc_scaled_q33_31;
  logic signed [31:0] acc_scaled_q16_16;
  logic signed [33:0] v_mul_q9_23;
  logic signed [31:0] v_term_q16_16;
  logic signed [31:0] acc_new_q16_16;

  fa_exp_pwl_8seg_q1_15 u_exp_old (
    .i_x_q8_8(diff_old_q8_8),
    .o_exp_q1_15(exp_old_q1_15)
  );

  fa_exp_pwl_8seg_q1_15 u_exp_new (
    .i_x_q8_8(diff_new_q8_8),
    .o_exp_q1_15(exp_new_q1_15)
  );

  always_comb begin
    if (i_score_q8_8 > m_reg) begin
      m_new = i_score_q8_8;
    end else begin
      m_new = m_reg;
    end

    diff_old_q8_8 = m_reg - m_new;
    diff_new_q8_8 = i_score_q8_8 - m_new;

    l_scaled_q32_31 = l_reg * exp_old_q1_15;
    l_scaled_q16_16 = l_scaled_q32_31[46:15];
    l_term_q16_16 = {15'd0, exp_new_q1_15, 1'b0};
    l_new_q16_16 = l_scaled_q16_16 + l_term_q16_16;

    acc_scaled_q33_31 = acc_reg * $signed({1'b0, exp_old_q1_15});
    acc_scaled_q16_16 = acc_scaled_q33_31[46:15];

    v_mul_q9_23 = $signed({1'b0, exp_new_q1_15}) * i_value_q8_8;
    v_term_q16_16 = {{5{v_mul_q9_23[33]}}, v_mul_q9_23[33:7]};
    acc_new_q16_16 = acc_scaled_q16_16 + v_term_q16_16;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_reg <= -16'sd32768;
      l_reg <= 32'd0;
      acc_reg <= 32'sd0;
      o_row_done <= 1'b0;
    end else begin
      o_row_done <= 1'b0;

      if (i_row_start) begin
        m_reg <= -16'sd32768;
        l_reg <= 32'd0;
        acc_reg <= 32'sd0;
      end

      if (i_valid) begin
        m_reg <= m_new;
        l_reg <= l_new_q16_16;
        acc_reg <= acc_new_q16_16;

        if (i_row_end) begin
          o_row_done <= 1'b1;
        end
      end
    end
  end

  assign o_m_q8_8 = m_reg;
  assign o_l_q16_16 = l_reg;
  assign o_acc_q16_16 = acc_reg;
endmodule
