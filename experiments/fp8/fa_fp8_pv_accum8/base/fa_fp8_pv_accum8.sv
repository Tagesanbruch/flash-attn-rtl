module fa_fp8_pv_accum8 (
  input  logic [63:0] i_v_vec,
  input  logic signed [15:0] i_weight_q0_15,
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

  logic signed [39:0] sum_q4_26;
  logic signed [15:0] v_q4_11;

  always_comb begin
    sum_q4_26 = 40'sd0;
    for (int i = 0; i < 8; i++) begin
      v_q4_11 = fp8_e4m3_to_q4_11(i_v_vec[i*8 +: 8]);
      sum_q4_26 = sum_q4_26 + ($signed(v_q4_11) * $signed(i_weight_q0_15));
    end
    o_ctx_q4_11 = sum_q4_26 >>> 15;
  end
endmodule
