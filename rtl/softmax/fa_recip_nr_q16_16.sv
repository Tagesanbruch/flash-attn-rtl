module fa_recip_nr_q16_16 (
  input  logic [31:0] i_x_q16_16,
  output logic [31:0] o_recip_q16_16
);
  logic [63:0] num;
  logic [63:0] quot;

  always_comb begin
    num = 64'h0000_0001_0000_0000;
    quot = 64'd0;
    if (i_x_q16_16 == 32'd0) begin
      o_recip_q16_16 = 32'hFFFF_FFFF;
    end else begin
      quot = num / {32'd0, i_x_q16_16};
      if (quot > 64'h0000_0000_FFFF_FFFF) begin
        o_recip_q16_16 = 32'hFFFF_FFFF;
      end else begin
        o_recip_q16_16 = quot[31:0];
      end
    end
  end
endmodule
