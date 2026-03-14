module fa_fp16_to_fp32 (
  input  logic [15:0] i_x_fp16,
  output logic [31:0] o_y_fp32
);
  logic sign;
  logic [4:0] exp_fp16;
  logic [9:0] frac_fp16;
  logic [10:0] mant_norm;
  logic [7:0] exp_fp32;
  logic [22:0] frac_fp32;
  int shift;

  always_comb begin
    sign = i_x_fp16[15];
    exp_fp16 = i_x_fp16[14:10];
    frac_fp16 = i_x_fp16[9:0];
    mant_norm = {1'b0, frac_fp16};
    shift = 0;
    exp_fp32 = 8'd0;
    frac_fp32 = 23'd0;

    if (exp_fp16 == 5'h00) begin
      if (frac_fp16 == 10'd0) begin
        exp_fp32 = 8'd0;
        frac_fp32 = 23'd0;
      end else begin
        shift = 0;
        while ((mant_norm[10] == 1'b0) && (shift < 10)) begin
          mant_norm = mant_norm << 1;
          shift = shift + 1;
        end
        exp_fp32 = 8'd113 - shift;
        frac_fp32 = {mant_norm[9:0], 13'd0};
      end
    end else if (exp_fp16 == 5'h1F) begin
      exp_fp32 = 8'hFF;
      frac_fp32 = (frac_fp16 == 10'd0) ? 23'd0 : {frac_fp16, 13'd0};
    end else begin
      exp_fp32 = exp_fp16 + 8'd112;
      frac_fp32 = {frac_fp16, 13'd0};
    end

    o_y_fp32 = {sign, exp_fp32, frac_fp32};
  end
endmodule
