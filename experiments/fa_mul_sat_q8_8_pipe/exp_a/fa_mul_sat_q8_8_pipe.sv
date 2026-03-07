module fa_mul_sat_q8_8_pipe (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               i_valid,
  input  logic signed [15:0] i_a_q8_8,
  input  logic signed [15:0] i_b_q8_8,
  output logic               o_valid,
  output logic signed [15:0] o_y_q8_8
);
  logic               s0_valid;
  logic signed [15:0] s0_a_q8_8;
  logic signed [15:0] s0_b_q8_8;
  logic               s1_valid;
  logic signed [31:0] s1_prod_q16_16;

  logic signed [31:0] rounded_q16_16;
  logic signed [31:0] shifted_q8_8;
  logic               pos_overflow;
  logic               neg_overflow;
  logic signed [15:0] sat_q8_8;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s0_valid   <= 1'b0;
      s0_a_q8_8 <= 16'sd0;
      s0_b_q8_8 <= 16'sd0;
    end else begin
      s0_valid   <= i_valid;
      s0_a_q8_8 <= i_a_q8_8;
      s0_b_q8_8 <= i_b_q8_8;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid        <= 1'b0;
      s1_prod_q16_16 <= 32'sd0;
    end else begin
      s1_valid        <= s0_valid;
      s1_prod_q16_16 <= s0_a_q8_8 * s0_b_q8_8;
    end
  end

  always_comb begin
    rounded_q16_16 = s1_prod_q16_16 + 32'sd128 - {23'd0, s1_prod_q16_16[31], 8'd0};
    shifted_q8_8   = rounded_q16_16 >>> 8;

    pos_overflow = ~shifted_q8_8[31] & (|shifted_q8_8[30:15]);
    neg_overflow = shifted_q8_8[31] & (~&shifted_q8_8[30:15]);

    if (pos_overflow) begin
      sat_q8_8 = 16'sd32767;
    end else if (neg_overflow) begin
      sat_q8_8 = -16'sd32768;
    end else begin
      sat_q8_8 = shifted_q8_8[15:0];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_valid   <= 1'b0;
      o_y_q8_8 <= 16'sd0;
    end else begin
      o_valid <= s1_valid;
      if (s1_valid) begin
        o_y_q8_8 <= sat_q8_8;
      end
    end
  end
endmodule
