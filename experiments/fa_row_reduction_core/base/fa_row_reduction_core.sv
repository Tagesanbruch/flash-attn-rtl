module fa_row_reduction_core (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                i_row_start,
  input  logic                i_valid,
  input  logic                i_row_end,
  input  logic signed [15:0]  i_score_q8_8,
  input  logic signed [15:0]  i_value_q8_8,
  output logic signed [15:0]  o_row_out_q8_8,
  output logic                o_row_out_valid
);
  logic signed [15:0] m_q8_8_unused;
  logic [31:0] l_q16_16;
  logic signed [31:0] acc_q16_16;
  logic row_done;
  logic [31:0] recip_q16_16;
  logic signed [63:0] norm_mul_q32_32;
  logic signed [31:0] norm_q16_16;
  logic signed [63:0] norm_shifted;

  fa_online_softmax_update u_online (
    .clk(clk),
    .rst_n(rst_n),
    .i_row_start(i_row_start),
    .i_valid(i_valid),
    .i_row_end(i_row_end),
    .i_score_q8_8(i_score_q8_8),
    .i_value_q8_8(i_value_q8_8),
    .o_m_q8_8(m_q8_8_unused),
    .o_l_q16_16(l_q16_16),
    .o_acc_q16_16(acc_q16_16),
    .o_row_done(row_done)
  );

  fa_recip_nr_q16_16 u_recip (
    .i_x_q16_16(l_q16_16),
    .o_recip_q16_16(recip_q16_16)
  );

  always_comb begin
    norm_mul_q32_32 = acc_q16_16 * $signed({1'b0, recip_q16_16});
    norm_shifted = norm_mul_q32_32 >>> 16;
    norm_q16_16 = norm_shifted[31:0];

    if (norm_q16_16 > 32'sd32767) begin
      o_row_out_q8_8 = 16'sd32767;
    end else if (norm_q16_16 < -32'sd32768) begin
      o_row_out_q8_8 = -16'sd32768;
    end else begin
      o_row_out_q8_8 = norm_q16_16[15:0];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_row_out_valid <= 1'b0;
    end else begin
      o_row_out_valid <= row_done;
    end
  end
endmodule
