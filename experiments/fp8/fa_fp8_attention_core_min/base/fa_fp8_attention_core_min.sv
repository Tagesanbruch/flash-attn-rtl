module fa_fp8_attention_core_min (
  input  logic [63:0] i_q_vec,
  input  logic [63:0] i_k_vec,
  input  logic [63:0] i_v_vec,
  input  logic signed [15:0] i_score_scale_q1_14,
  input  logic [1:0] i_round_mode,
  input  logic       i_saturate_en,
  output logic signed [31:0] o_score_q8_11,
  output logic signed [15:0] o_weight_q0_15,
  output logic signed [31:0] o_ctx_q4_11
);
  function automatic signed [15:0] fp8_e4m3_to_q4_11(input logic [7:0] fp8);
    logic sign;
    logic [3:0] exp;
    logic [2:0] frac;
    logic signed [31:0] mag;
    begin
      sign = fp8[7];
      exp = fp8[6:3];
      frac = fp8[2:0];
      if (exp == 4'd0) begin
        mag = $signed({1'b0, frac}) <<< 2;
      end else if (exp == 4'hF) begin
        mag = 32'sd32767;
      end else begin
        mag = $signed({1'b0, 3'd0, 1'b1, frac}) <<< (exp + 1);
        if (mag > 32'sd32767) begin
          mag = 32'sd32767;
        end
      end
      fp8_e4m3_to_q4_11 = sign ? -mag[15:0] : mag[15:0];
    end
  endfunction

  function automatic signed [39:0] round_shift_right_40(
    input signed [39:0] v,
    input int sh,
    input logic [1:0] round_mode
  );
    logic signed [39:0] t;
    begin
      t = v;
      if (sh <= 0) begin
        round_shift_right_40 = v;
      end else begin
        if (round_mode == 2'd1) begin
          if (v >= 0) begin
            t = v + (40'sd1 <<< (sh - 1));
          end else begin
            t = v - (40'sd1 <<< (sh - 1));
          end
        end
        round_shift_right_40 = t >>> sh;
      end
    end
  endfunction

  logic signed [39:0] dot_q8_22;
  logic signed [39:0] score_q8_11_w;
  logic signed [55:0] score_scaled_q9_25;
  logic signed [55:0] score_scaled_q8_11;
  logic signed [31:0] score_q8_3;
  logic [4:0] neg_shift;
  logic signed [39:0] pv_sum_q4_26;

  always_comb begin
    dot_q8_22 = 40'sd0;
    for (int i = 0; i < 8; i++) begin
      dot_q8_22 = dot_q8_22 +
        ($signed(fp8_e4m3_to_q4_11(i_q_vec[i*8 +: 8])) *
         $signed(fp8_e4m3_to_q4_11(i_k_vec[i*8 +: 8])));
    end

    score_q8_11_w = round_shift_right_40(dot_q8_22, 11, i_round_mode);
    score_scaled_q9_25 = score_q8_11_w * $signed(i_score_scale_q1_14);
    score_scaled_q8_11 = score_scaled_q9_25 >>> 14;

    if (i_saturate_en) begin
      if (score_scaled_q8_11 > 56'sd2147483647) begin
        o_score_q8_11 = 32'sd2147483647;
      end else if (score_scaled_q8_11 < -56'sd2147483648) begin
        o_score_q8_11 = -32'sd2147483648;
      end else begin
        o_score_q8_11 = score_scaled_q8_11[31:0];
      end
    end else begin
      o_score_q8_11 = score_scaled_q8_11[31:0];
    end

    // Softmax prep minimum path: exp2-like shift approximation in Q0.15.
    score_q8_3 = o_score_q8_11 >>> 8;
    neg_shift = 5'd0;
    if (score_q8_3 >= 0) begin
      o_weight_q0_15 = 16'sd32767;
    end else if (score_q8_3 <= -8'sd15) begin
      o_weight_q0_15 = 16'sd0;
    end else begin
      neg_shift = -score_q8_3;
      o_weight_q0_15 = 16'sd32767 >>> neg_shift;
    end

    pv_sum_q4_26 = 40'sd0;
    for (int j = 0; j < 8; j++) begin
      pv_sum_q4_26 = pv_sum_q4_26 +
        ($signed(fp8_e4m3_to_q4_11(i_v_vec[j*8 +: 8])) * $signed(o_weight_q0_15));
    end
    o_ctx_q4_11 = pv_sum_q4_26 >>> 15;
  end
endmodule
