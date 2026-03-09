module fa_online_softmax_ctx (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                i_valid,
  input  logic                i_row_start,
  input  logic                i_row_end,
  input  logic [1:0]          i_ctx_id,
  input  logic signed [15:0]  i_score_q8_8,
  input  logic signed [15:0]  i_value_q8_8,
  output logic                o_valid,
  output logic                o_row_done,
  output logic [1:0]          o_ctx_id,
  output logic signed [15:0]  o_m_q8_8,
  output logic        [31:0]  o_l_q16_16,
  output logic signed [31:0]  o_acc_q16_16
);
  localparam int CTX_COUNT = 2;
  localparam int LOG2E_Q8_8 = 16'sd369;

  logic signed [15:0] m_state   [CTX_COUNT];
  logic        [31:0] l_state   [CTX_COUNT];
  logic signed [31:0] acc_state [CTX_COUNT];

  logic               s0_valid, s0_row_end;
  logic [1:0]         s0_ctx_id;
  logic signed [15:0] s0_score, s0_value;
  logic signed [15:0] s0_m_prev;
  logic [31:0]        s0_l_prev;
  logic signed [31:0] s0_acc_prev;

  logic               s1_valid, s1_row_end;
  logic [1:0]         s1_ctx_id;
  logic signed [15:0] s1_m_new;
  logic [31:0]        s1_l_new;
  logic signed [31:0] s1_acc_new;

  function automatic [15:0] exp2_approx(input logic signed [15:0] x_q8_8);
    logic signed [15:0] x_clip_q8_8;
    logic [15:0] mag_q8_8;
    logic [31:0] z_mul_q16_16;
    logic [15:0] z_q8_8;
    logic [7:0]  int_part;
    logic [7:0]  frac_part;
    logic [15:0] frac_val;
    begin
      if (x_q8_8 > 16'sd0)
        x_clip_q8_8 = 16'sd0;
      else if (x_q8_8 < -16'sd4096)
        x_clip_q8_8 = -16'sd4096;
      else
        x_clip_q8_8 = x_q8_8;
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
      if (int_part >= 8'd16)
        exp2_approx = 16'd0;
      else
        exp2_approx = frac_val >> int_part;
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    int idx;
    logic signed [15:0] m_new;
    logic signed [15:0] diff_old_q8_8;
    logic signed [15:0] diff_new_q8_8;
    logic [15:0]        exp_old_q1_15;
    logic [15:0]        exp_new_q1_15;
    logic [63:0]        l_scaled_q32_31;
    logic [31:0]        l_new_q16_16;
    logic signed [63:0] acc_scaled_q33_31;
    logic signed [33:0] v_mul_q9_23;
    logic signed [31:0] acc_new_q16_16;

    if (!rst_n) begin
      for (int c = 0; c < CTX_COUNT; c++) begin
        m_state[c] <= -16'sd32768;
        l_state[c] <= 32'd0;
        acc_state[c] <= 32'sd0;
      end
      s0_valid <= 1'b0;
      s1_valid <= 1'b0;
      o_valid <= 1'b0;
      o_row_done <= 1'b0;
      o_ctx_id <= 2'd0;
      o_m_q8_8 <= -16'sd32768;
      o_l_q16_16 <= 32'd0;
      o_acc_q16_16 <= 32'sd0;
    end else begin
      if (i_valid) begin
        idx = i_ctx_id[0];
        s0_valid <= 1'b1;
        s0_row_end <= i_row_end;
        s0_ctx_id <= i_ctx_id;
        s0_score <= i_score_q8_8;
        s0_value <= i_value_q8_8;
        s0_m_prev <= i_row_start ? -16'sd32768 : m_state[idx];
        s0_l_prev <= i_row_start ? 32'd0 : l_state[idx];
        s0_acc_prev <= i_row_start ? 32'sd0 : acc_state[idx];
      end else begin
        s0_valid <= 1'b0;
      end

      if (s0_valid) begin
        idx = s0_ctx_id[0];
        m_new = (s0_score > s0_m_prev) ? s0_score : s0_m_prev;
        diff_old_q8_8 = s0_m_prev - m_new;
        diff_new_q8_8 = s0_score - m_new;
        exp_old_q1_15 = exp2_approx(diff_old_q8_8);
        exp_new_q1_15 = exp2_approx(diff_new_q8_8);
        l_scaled_q32_31 = s0_l_prev * exp_old_q1_15;
        l_new_q16_16 = l_scaled_q32_31[46:15] + {15'd0, exp_new_q1_15, 1'b0};
        acc_scaled_q33_31 = s0_acc_prev * $signed({1'b0, exp_old_q1_15});
        v_mul_q9_23 = $signed({1'b0, exp_new_q1_15}) * s0_value;
        acc_new_q16_16 = acc_scaled_q33_31[46:15] + {{5{v_mul_q9_23[33]}}, v_mul_q9_23[33:7]};

        m_state[idx] <= m_new;
        l_state[idx] <= l_new_q16_16;
        acc_state[idx] <= acc_new_q16_16;

        s1_valid <= 1'b1;
        s1_row_end <= s0_row_end;
        s1_ctx_id <= s0_ctx_id;
        s1_m_new <= m_new;
        s1_l_new <= l_new_q16_16;
        s1_acc_new <= acc_new_q16_16;
      end else begin
        s1_valid <= 1'b0;
      end

      o_valid <= s1_valid;
      o_row_done <= s1_valid && s1_row_end;
      o_ctx_id <= s1_ctx_id;
      o_m_q8_8 <= s1_m_new;
      o_l_q16_16 <= s1_l_new;
      o_acc_q16_16 <= s1_acc_new;
    end
  end
endmodule