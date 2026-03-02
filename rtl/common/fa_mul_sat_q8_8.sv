module fa_mul_sat_q8_8 (
  input  logic signed [15:0] i_a_q8_8,
  input  logic signed [15:0] i_b_q8_8,
  output logic signed [15:0] o_y_q8_8
);
  logic signed [31:0] prod_q16_16;
  logic signed [31:0] rounded_q16_16;
  logic signed [31:0] shifted_q8_8;

  always_comb begin
    prod_q16_16 = i_a_q8_8 * i_b_q8_8;
    if (prod_q16_16 >= 0) begin
      rounded_q16_16 = prod_q16_16 + 32'sd128;
    end else begin
      rounded_q16_16 = prod_q16_16 - 32'sd128;
    end
    shifted_q8_8 = rounded_q16_16 >>> 8;

    if (shifted_q8_8 > 32'sd32767) begin
      o_y_q8_8 = 16'sd32767;
    end else if (shifted_q8_8 < -32'sd32768) begin
      o_y_q8_8 = -16'sd32768;
    end else begin
      o_y_q8_8 = shifted_q8_8[15:0];
    end
  end
endmodule
