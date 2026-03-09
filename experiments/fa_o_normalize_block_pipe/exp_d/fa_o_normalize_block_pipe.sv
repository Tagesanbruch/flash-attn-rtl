module fa_o_normalize_block_pipe #(
  parameter int LANES = 8
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     i_valid,
  input  logic                     i_den_zero,
  input  logic [31:0]              i_recip_q16_16,
  input  logic [LANES*64-1:0]      i_acc_flat,
  output logic                     o_valid,
  output logic [LANES*16-1:0]      o_data_flat
);

  function automatic logic signed [63:0] lane64(
    input logic [LANES*64-1:0] vec,
    input int                  idx
  );
    lane64 = $signed(vec[idx*64 +: 64]);
  endfunction

  function automatic logic signed [15:0] sat16(
    input logic signed [79:0] value
  );
    begin
      if (value > 80'sd32767)
        sat16 = 16'sd32767;
      else if (value < -80'sd32768)
        sat16 = -16'sd32768;
      else
        sat16 = value[15:0];
    end
  endfunction

  logic                 s0_valid, s0_den_zero;
  logic signed [63:0]   s0_acc [LANES];
  logic signed [80:0]   s0_pp_lo [LANES];
  logic signed [80:0]   s0_pp_hi [LANES];

  logic                 s1_valid;
  logic signed [79:0]   s1_res [LANES];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s0_valid <= 1'b0;
      s0_den_zero <= 1'b0;
      s1_valid <= 1'b0;
      o_valid <= 1'b0;
      o_data_flat <= '0;
      for (int lane = 0; lane < LANES; lane++) begin
        s0_acc[lane] <= '0;
        s0_pp_lo[lane] <= '0;
        s0_pp_hi[lane] <= '0;
        s1_res[lane] <= '0;
      end
    end else begin
      s0_valid <= i_valid;
      s0_den_zero <= i_den_zero;
      if (i_valid) begin
        for (int lane = 0; lane < LANES; lane++) begin
          s0_acc[lane] <= lane64(i_acc_flat, lane);
          s0_pp_lo[lane] <= lane64(i_acc_flat, lane) * $signed({1'b0, i_recip_q16_16[15:0]});
          s0_pp_hi[lane] <= lane64(i_acc_flat, lane) * $signed({1'b0, i_recip_q16_16[31:16]});
        end
      end

      s1_valid <= s0_valid;
      if (s0_valid) begin
        for (int lane = 0; lane < LANES; lane++) begin
          logic signed [111:0] norm_mul_q32_32;
          logic signed [111:0] norm_round_q32_32;
          if (s0_den_zero) begin
            s1_res[lane] <= (s0_acc[lane] >= 0) ? 80'sd32767 : -80'sd32768;
          end else begin
            norm_mul_q32_32 = $signed({{31{s0_pp_lo[lane][80]}}, s0_pp_lo[lane]}) +
                              ($signed({{31{s0_pp_hi[lane][80]}}, s0_pp_hi[lane]}) <<< 16);
            if (norm_mul_q32_32 >= 0)
              norm_round_q32_32 = norm_mul_q32_32 + 112'sd2147483648;
            else
              norm_round_q32_32 = norm_mul_q32_32 - 112'sd2147483648;
            s1_res[lane] <= norm_round_q32_32 >>> 32;
          end
        end
      end

      o_valid <= s1_valid;
      if (s1_valid) begin
        for (int lane = 0; lane < LANES; lane++)
          o_data_flat[lane*16 +: 16] <= sat16(s1_res[lane]);
      end
    end
  end
endmodule