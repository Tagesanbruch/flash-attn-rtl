module fa_fp8_softmax_prep_min (
  input  logic signed [31:0] i_score_q8_11,
  output logic signed [15:0] o_weight_q0_15
);
  logic signed [31:0] score_q8_3;
  logic [4:0] neg_shift;

  always_comb begin
    // Approximate exp2(score) in Q0.15 using shift domain.
    score_q8_3 = i_score_q8_11 >>> 8;
    neg_shift = 5'd0;
    if (score_q8_3 >= 0) begin
      o_weight_q0_15 = 16'sd32767;
    end else if (score_q8_3 <= -8'sd15) begin
      o_weight_q0_15 = 16'sd0;
    end else begin
      neg_shift = -score_q8_3;
      o_weight_q0_15 = 16'sd32767 >>> neg_shift;
    end
  end
endmodule
