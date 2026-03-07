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

      case (frac_part[7:3])
        5'd0: frac_val = 16'd32768;
        5'd1: frac_val = 16'd32066;
        5'd2: frac_val = 16'd31379;
        5'd3: frac_val = 16'd30706;
        5'd4: frac_val = 16'd30048;
        5'd5: frac_val = 16'd29405;
        5'd6: frac_val = 16'd28774;
        5'd7: frac_val = 16'd28158;
        5'd8: frac_val = 16'd27554;
        5'd9: frac_val = 16'd26964;
        5'd10: frac_val = 16'd26386;
        5'd11: frac_val = 16'd25821;
        5'd12: frac_val = 16'd25268;
        5'd13: frac_val = 16'd24726;
        5'd14: frac_val = 16'd24196;
        5'd15: frac_val = 16'd23678;
        5'd16: frac_val = 16'd23170;
        5'd17: frac_val = 16'd22674;
        5'd18: frac_val = 16'd22188;
        5'd19: frac_val = 16'd21713;
        5'd20: frac_val = 16'd21247;
        5'd21: frac_val = 16'd20792;
        5'd22: frac_val = 16'd20347;
        5'd23: frac_val = 16'd19911;
        5'd24: frac_val = 16'd19484;
        5'd25: frac_val = 16'd19066;
        5'd26: frac_val = 16'd18658;
        5'd27: frac_val = 16'd18258;
        5'd28: frac_val = 16'd17867;
        5'd29: frac_val = 16'd17484;
        5'd30: frac_val = 16'd17109;
        default: frac_val = 16'd16743;
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
