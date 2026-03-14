module fa_fp8_e4m3_to_fixed16 (
  input  logic [7:0] i_fp8,
  output logic signed [15:0] o_q4_11
);
  logic sign;
  logic [3:0] exp;
  logic [2:0] frac;
  logic signed [31:0] mag;
  logic [4:0] shift;

  always_comb begin
    sign = i_fp8[7];
    exp = i_fp8[6:3];
    frac = i_fp8[2:0];
    mag = 32'sd0;
    shift = 5'd0;

    if (exp == 4'd0) begin
      // Subnormal: value = frac * 2^-9, converted to Q4.11 => frac * 2^2.
      mag = $signed({1'b0, frac}) <<< 2;
    end else if (exp == 4'hF) begin
      mag = 32'sd32767;
    end else begin
      // Normal: value = (1 + frac/8) * 2^(exp-7), converted to Q4.11.
      shift = exp + 1;
      mag = $signed({1'b0, 3'd0, 1'b1, frac}) <<< shift;
      if (mag > 32'sd32767) begin
        mag = 32'sd32767;
      end
    end

    if (sign) begin
      o_q4_11 = -mag[15:0];
    end else begin
      o_q4_11 = mag[15:0];
    end
  end
endmodule
