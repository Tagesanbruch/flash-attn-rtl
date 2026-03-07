module fa_online_softmax_base2 (
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
  localparam int LOG2E_Q8_8 = 16'sd369;

  function automatic [15:0] exp2_approx(input logic signed [15:0] x_q8_8);
    logic signed [15:0] x_clip_q8_8;
    logic [15:0] mag_q8_8;
    logic [31:0] z_mul_q16_16;
    logic [15:0] z_q8_8;
    logic [7:0] int_part;
    logic [7:0] frac_part;
    logic [15:0] frac_val;
    begin
      if (x_q8_8 > 16'sd0) begin
        x_clip_q8_8 = 16'sd0;
      end else if (x_q8_8 < -16'sd4096) begin
        x_clip_q8_8 = -16'sd4096;
      end else begin
        x_clip_q8_8 = x_q8_8;
      end

      mag_q8_8 = $unsigned(-x_clip_q8_8);
      z_mul_q16_16 = mag_q8_8 * LOG2E_Q8_8;
      z_q8_8 = (z_mul_q16_16 + 32'd128) >> 8;
      int_part = z_q8_8[15:8];
      frac_part = z_q8_8[7:0];

      case (frac_part[7:4])
        4'd0: frac_val = 16'd32768;
        4'd1: frac_val = 16'd31379;
        4'd2: frac_val = 16'd30048;
        4'd3: frac_val = 16'd28774;
        4'd4: frac_val = 16'd27554;
        4'd5: frac_val = 16'd26386;
        4'd6: frac_val = 16'd25268;
        4'd7: frac_val = 16'd24196;
        4'd8: frac_val = 16'd23170;
        4'd9: frac_val = 16'd22188;
        4'd10: frac_val = 16'd21247;
        4'd11: frac_val = 16'd20347;
        4'd12: frac_val = 16'd19484;
        4'd13: frac_val = 16'd18658;
        4'd14: frac_val = 16'd17867;
        default: frac_val = 16'd17109;
      endcase

      if (int_part >= 8'd16) begin
        exp2_approx = 16'd0;
      end else begin
        exp2_approx = frac_val >> int_part;
      end
    end
  endfunction

  logic signed [15:0] m_reg;
  logic        [31:0] l_reg;
  logic signed [31:0] acc_reg;
  logic signed [15:0] m_new;
  logic signed [15:0] diff_old_q8_8;
  logic signed [15:0] diff_new_q8_8;
  logic        [15:0] exp_old_q1_15;
  logic        [15:0] exp_new_q1_15;
  logic        [63:0] l_scaled_q32_31;
  logic        [31:0] l_scaled_q16_16;
  logic        [31:0] l_term_q16_16;
  logic        [31:0] l_new_q16_16;
  logic signed [63:0] acc_scaled_q33_31;
  logic signed [31:0] acc_scaled_q16_16;
  logic signed [33:0] v_mul_q9_23;
  logic signed [31:0] v_term_q16_16;
  logic signed [31:0] acc_new_q16_16;

  always_comb begin
    if (i_row_start) begin
      m_new = i_score_q8_8;
    end else begin
      m_new = (i_score_q8_8 > m_reg) ? i_score_q8_8 : m_reg;
    end

    diff_old_q8_8 = (i_row_start ? -16'sd32768 : m_reg) - m_new;
    diff_new_q8_8 = i_score_q8_8 - m_new;
    exp_old_q1_15 = exp2_approx(diff_old_q8_8);
    exp_new_q1_15 = exp2_approx(diff_new_q8_8);

    l_scaled_q32_31 = (i_row_start ? 32'd0 : l_reg) * exp_old_q1_15;
    l_scaled_q16_16 = l_scaled_q32_31[46:15];
    l_term_q16_16 = {15'd0, exp_new_q1_15, 1'b0};
    l_new_q16_16 = l_scaled_q16_16 + l_term_q16_16;

    acc_scaled_q33_31 = (i_row_start ? 32'sd0 : acc_reg) * $signed({1'b0, exp_old_q1_15});
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
