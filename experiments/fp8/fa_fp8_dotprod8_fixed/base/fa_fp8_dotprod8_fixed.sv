module fa_fp8_dotprod8_fixed (
  input  logic [63:0] i_a_vec,
  input  logic [63:0] i_b_vec,
  output logic signed [31:0] o_dot_q8_11
);
  logic [7:0] a_i;
  logic [7:0] b_i;
  logic signed [15:0] a_q4_11;
  logic signed [15:0] b_q4_11;
  logic signed [39:0] prod_q8_22;
  logic signed [39:0] sum_q8_22;

  function automatic signed [15:0] fp8_e4m3_to_q4_11(input logic [7:0] fp8);
    logic sign;
    logic [3:0] exp;
    logic [2:0] frac;
    logic signed [31:0] mag;
    logic [4:0] shift;
    begin
      sign = fp8[7];
      exp = fp8[6:3];
      frac = fp8[2:0];
      mag = 32'sd0;
      shift = 5'd0;

      if (exp == 4'd0) begin
        mag = $signed({1'b0, frac}) <<< 2;
      end else if (exp == 4'hF) begin
        mag = 32'sd32767;
      end else begin
        shift = exp + 1;
        mag = $signed({1'b0, 3'd0, 1'b1, frac}) <<< shift;
        if (mag > 32'sd32767)
          mag = 32'sd32767;
      end

      if (sign)
        fp8_e4m3_to_q4_11 = -mag[15:0];
      else
        fp8_e4m3_to_q4_11 = mag[15:0];
    end
  endfunction

  always_comb begin
    sum_q8_22 = 32'sd0;
    for (int i = 0; i < 8; i++) begin
      a_i = i_a_vec[i*8 +: 8];
      b_i = i_b_vec[i*8 +: 8];
      a_q4_11 = fp8_e4m3_to_q4_11(a_i);
      b_q4_11 = fp8_e4m3_to_q4_11(b_i);
      prod_q8_22 = $signed(a_q4_11) * $signed(b_q4_11);
      sum_q8_22 = sum_q8_22 + prod_q8_22;
    end
    o_dot_q8_11 = sum_q8_22 >>> 11;
  end
endmodule
