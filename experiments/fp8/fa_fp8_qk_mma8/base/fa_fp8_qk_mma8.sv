module fa_fp8_qk_mma8 (
  input  logic [63:0] i_q_vec,
  input  logic [63:0] i_k_vec,
  input  logic [1:0]  i_round_mode,
  input  logic        i_saturate_en,
  output logic signed [31:0] o_score_q8_11
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

  logic [7:0] q_i;
  logic [7:0] k_i;
  logic signed [15:0] q_q4_11;
  logic signed [15:0] k_q4_11;
  logic signed [39:0] prod_q8_22;
  logic signed [39:0] sum_q8_22;
  logic signed [39:0] score_q8_11;

  always_comb begin
    sum_q8_22 = 40'sd0;
    for (int i = 0; i < 8; i++) begin
      q_i = i_q_vec[i*8 +: 8];
      k_i = i_k_vec[i*8 +: 8];
      q_q4_11 = fp8_e4m3_to_q4_11(q_i);
      k_q4_11 = fp8_e4m3_to_q4_11(k_i);
      prod_q8_22 = $signed(q_q4_11) * $signed(k_q4_11);
      sum_q8_22 = sum_q8_22 + prod_q8_22;
    end

    score_q8_11 = round_shift_right_40(sum_q8_22, 11, i_round_mode);

    if (i_saturate_en) begin
      if (score_q8_11 > 40'sd2147483647) begin
        o_score_q8_11 = 32'sd2147483647;
      end else if (score_q8_11 < -40'sd2147483648) begin
        o_score_q8_11 = -32'sd2147483648;
      end else begin
        o_score_q8_11 = score_q8_11[31:0];
      end
    end else begin
      o_score_q8_11 = score_q8_11[31:0];
    end
  end
endmodule
