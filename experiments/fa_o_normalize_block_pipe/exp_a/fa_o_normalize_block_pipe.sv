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
  localparam int HALF = LANES / 2;

  function automatic logic signed [63:0] lane64(
    input logic [LANES*64-1:0] vec,
    input int                  idx
  );
    lane64 = $signed(vec[idx*64 +: 64]);
  endfunction

  function automatic logic signed [15:0] norm_lane(
    input logic                den_zero,
    input logic [31:0]         recip_q16_16,
    input logic signed [63:0]  acc_q32_32
  );
    logic signed [95:0] norm_mul_q32_32;
    logic signed [95:0] norm_rounded_q32_32;
    logic signed [79:0] norm_result;
    begin
      norm_mul_q32_32 = '0;
      norm_rounded_q32_32 = '0;
      norm_result = '0;
      if (den_zero) begin
        norm_result = (acc_q32_32 >= 0) ? 80'sd32767 : -80'sd32768;
      end else begin
        norm_mul_q32_32 = acc_q32_32 * $signed({1'b0, recip_q16_16});
        if (norm_mul_q32_32 >= 0)
          norm_rounded_q32_32 = norm_mul_q32_32 + 96'sd2147483648;
        else
          norm_rounded_q32_32 = norm_mul_q32_32 - 96'sd2147483648;
        norm_result = norm_rounded_q32_32 >>> 32;
      end

      if (norm_result > 80'sd32767)
        norm_lane = 16'sd32767;
      else if (norm_result < -80'sd32768)
        norm_lane = -16'sd32768;
      else
        norm_lane = norm_result[15:0];
    end
  endfunction

  logic [HALF*16-1:0] lo_c, hi_c;
  logic [HALF*16-1:0] lo_r, hi_r;
  logic               valid_r;

  always_comb begin
    for (int lane = 0; lane < HALF; lane++) begin
      lo_c[lane*16 +: 16] = norm_lane(i_den_zero, i_recip_q16_16, lane64(i_acc_flat, lane));
      hi_c[lane*16 +: 16] = norm_lane(i_den_zero, i_recip_q16_16, lane64(i_acc_flat, lane + HALF));
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lo_r <= '0;
      hi_r <= '0;
      valid_r <= 1'b0;
      o_valid <= 1'b0;
      o_data_flat <= '0;
    end else begin
      lo_r <= lo_c;
      hi_r <= hi_c;
      valid_r <= i_valid;
      o_valid <= valid_r;
      if (valid_r)
        o_data_flat <= {hi_r, lo_r};
    end
  end
endmodule