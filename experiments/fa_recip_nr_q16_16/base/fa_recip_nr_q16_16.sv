module fa_recip_nr_q16_16 (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        i_valid,
  input  logic [31:0] i_x_q16_16,
  output logic        o_valid,
  output logic [31:0] o_recip_q16_16
);
  logic [63:0] num;
  logic [63:0] quot;
  logic [31:0] result_comb;

  always_comb begin
    num = 64'h0000_0001_0000_0000;
    quot = 64'd0;
    if (i_x_q16_16 == 32'd0) begin
      result_comb = 32'hFFFF_FFFF;
    end else begin
      quot = num / {32'd0, i_x_q16_16};
      if (quot > 64'h0000_0000_FFFF_FFFF) begin
        result_comb = 32'hFFFF_FFFF;
      end else begin
        result_comb = quot[31:0];
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_valid <= 1'b0;
      o_recip_q16_16 <= 32'd0;
    end else begin
      o_valid <= i_valid;
      o_recip_q16_16 <= result_comb;
    end
  end
endmodule
