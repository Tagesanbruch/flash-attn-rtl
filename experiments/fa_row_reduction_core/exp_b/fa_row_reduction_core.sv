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

  // ─── Pipelined normalization path ──────────────────────────────
  // Pipeline stage 0: Latch acc & l on row_done, start NR
  logic        norm_start;
  logic [31:0] norm_l_latched;
  logic signed [31:0] norm_acc_latched;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      norm_start      <= 1'b0;
      norm_l_latched  <= 32'd0;
      norm_acc_latched <= 32'sd0;
    end else begin
      norm_start <= row_done;
      if (row_done) begin
        norm_l_latched  <= l_q16_16;
        norm_acc_latched <= acc_q16_16;
      end
    end
  end

  // Pipeline stage 1-10: NR reciprocal (10-cycle latency, pipelined multiply)
  logic        recip_valid;
  logic [31:0] recip_q16_16;

  fa_recip_nr_q16_16 u_recip (
    .clk(clk),
    .rst_n(rst_n),
    .i_valid(norm_start),
    .i_x_q16_16(norm_l_latched),
    .o_valid(recip_valid),
    .o_recip_q16_16(recip_q16_16)
  );

  // Pipeline: delay acc to align with recip output (10 cycles through NR)
  logic signed [31:0] acc_delay [0:9];
  integer j;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (j = 0; j < 10; j = j + 1)
        acc_delay[j] <= 32'sd0;
    end else begin
      acc_delay[0] <= norm_acc_latched;
      for (j = 1; j < 10; j = j + 1)
        acc_delay[j] <= acc_delay[j-1];
    end
  end

  // Pipeline stage 11: Final multiply acc * recip + saturation
  logic signed [63:0] norm_mul_q32_32;
  logic signed [63:0] norm_shifted;
  logic signed [15:0] norm_sat;

  always_comb begin
    norm_mul_q32_32 = acc_delay[9] * $signed({1'b0, recip_q16_16});
    norm_shifted = norm_mul_q32_32 >>> 16;
    // Saturate on the full 64-bit value to avoid [31:0] truncation sign flip
    if (norm_shifted > 64'sd32767)
      norm_sat = 16'sd32767;
    else if (norm_shifted < -64'sd32768)
      norm_sat = -16'sd32768;
    else
      norm_sat = norm_shifted[15:0];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_row_out_valid <= 1'b0;
      o_row_out_q8_8  <= 16'sd0;
    end else begin
      o_row_out_valid <= recip_valid;
      if (recip_valid) begin
        o_row_out_q8_8 <= norm_sat;
      end
    end
  end
endmodule
