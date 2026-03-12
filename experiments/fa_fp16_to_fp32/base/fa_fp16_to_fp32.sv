module fa_fp16_to_fp32 (
  input  logic [15:0] i_x_fp16,
  output logic [31:0] o_y_fp32
);
  logic        sign;
  logic [4:0]  exp_fp16;
  logic [9:0]  frac_fp16;
  integer      msb_idx;
  logic [23:0] sig24;
  logic [7:0]  exp_fp32;

  always_comb begin
    sign     = i_x_fp16[15];
    exp_fp16 = i_x_fp16[14:10];
    frac_fp16 = i_x_fp16[9:0];
    o_y_fp32 = 32'd0;
    msb_idx  = -1;
    sig24    = 24'd0;
    exp_fp32 = 8'd0;

    if (exp_fp16 == 5'h1F) begin
      o_y_fp32 = {sign, 8'hFF, frac_fp16, 13'd0};
    end else if (exp_fp16 == 5'd0) begin
      if (frac_fp16 == 10'd0) begin
        o_y_fp32 = {sign, 31'd0};
      end else begin
        for (int i = 9; i >= 0; i--) begin
          if ((msb_idx == -1) && frac_fp16[i]) begin
            msb_idx = i;
          end
        end
        sig24 = {14'd0, frac_fp16} << (23 - msb_idx);
        exp_fp32 = msb_idx + 8'd103;
        o_y_fp32 = {sign, exp_fp32, sig24[22:0]};
      end
    end else begin
      o_y_fp32 = {sign, exp_fp16 + 8'd112, frac_fp16, 13'd0};
    end
  end
endmodule
