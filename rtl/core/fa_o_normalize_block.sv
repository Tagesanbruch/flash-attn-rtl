module fa_o_normalize_block #(
  parameter int NORM_LANES = 8
) (
  input  logic                     i_den_zero,
  input  logic [31:0]              i_recip_q16_16,
  input  logic signed [63:0]       i_acc [NORM_LANES],
  output logic signed [15:0]       o_data [NORM_LANES]
);

  always_comb begin
    for (int lane = 0; lane < NORM_LANES; lane++) begin
      logic signed [63:0] num;
      logic signed [95:0] norm_mul_q32_32;
      logic signed [95:0] norm_rounded_q32_32;
      logic signed [79:0] norm_result;

      num = i_acc[lane];
      norm_mul_q32_32 = '0;
      norm_rounded_q32_32 = '0;
      norm_result = '0;
      if (i_den_zero) begin
        norm_result = (num >= 0) ? 80'sd32767 : -80'sd32768;
      end else begin
        norm_mul_q32_32 = num * $signed({1'b0, i_recip_q16_16});
        if (norm_mul_q32_32 >= 0)
          norm_rounded_q32_32 = norm_mul_q32_32 + 96'sd2147483648;
        else
          norm_rounded_q32_32 = norm_mul_q32_32 - 96'sd2147483648;
        norm_result = norm_rounded_q32_32 >>> 32;
      end

      if (norm_result > 80'sd32767)
        o_data[lane] = 16'sd32767;
      else if (norm_result < -80'sd32768)
        o_data[lane] = -16'sd32768;
      else
        o_data[lane] = norm_result[15:0];
    end
  end
endmodule