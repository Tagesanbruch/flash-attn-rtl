module fa_fp32_to_fp16 (
  input  logic [31:0] i_x_fp32,
  output logic [15:0] o_y_fp16
);
  logic sign;
  logic [7:0] exp_fp32;
  logic [22:0] frac_fp32;
  logic [9:0] nan_payload;
  int exp_unbiased;
  int exp_half;
  logic [23:0] mant24;
  logic [31:0] mant_rounded;
  int shift_amt;

  function automatic [31:0] rshift_rne_u32(input [31:0] val, input int shamt);
    logic [31:0] base;
    logic guard;
    logic sticky;
    logic [31:0] sticky_mask;
    begin
      if (shamt <= 0) begin
        rshift_rne_u32 = val;
      end else if (shamt >= 32) begin
        rshift_rne_u32 = (val != 32'd0) ? 32'd1 : 32'd0;
      end else begin
        base = val >> shamt;
        guard = (val >> (shamt - 1)) & 1'b1;
        sticky_mask = (shamt > 1) ? ((32'd1 << (shamt - 1)) - 1) : 32'd0;
        sticky = ((val & sticky_mask) != 32'd0);
        if (guard && (sticky || base[0])) begin
          rshift_rne_u32 = base + 1'b1;
        end else begin
          rshift_rne_u32 = base;
        end
      end
    end
  endfunction

  always_comb begin
    sign = i_x_fp32[31];
    exp_fp32 = i_x_fp32[30:23];
    frac_fp32 = i_x_fp32[22:0];
    nan_payload = frac_fp32[22:13];
    mant24 = {1'b1, frac_fp32};
    exp_unbiased = 0;
    exp_half = 0;
    mant_rounded = 32'd0;
    shift_amt = 0;
    o_y_fp16 = {sign, 15'd0};

    if (exp_fp32 == 8'hFF) begin
      if (frac_fp32 == 23'd0) begin
        o_y_fp16 = {sign, 5'h1F, 10'd0};
      end else begin
        o_y_fp16 = {sign, 5'h1F, (nan_payload != 10'd0) ? nan_payload : 10'h200};
      end
    end else if (exp_fp32 == 8'h00) begin
      o_y_fp16 = {sign, 15'd0};
    end else begin
      exp_unbiased = exp_fp32 - 127;
      exp_half = exp_unbiased + 15;

      if (exp_half >= 31) begin
        o_y_fp16 = {sign, 5'h1F, 10'd0};
      end else if (exp_half <= 0) begin
        if (exp_half < -10) begin
          o_y_fp16 = {sign, 15'd0};
        end else begin
          shift_amt = 14 - exp_half;
          mant_rounded = rshift_rne_u32({8'd0, mant24}, shift_amt);
          if (mant_rounded >= 32'd1024) begin
            o_y_fp16 = {sign, 5'd1, 10'd0};
          end else begin
            o_y_fp16 = {sign, 5'd0, mant_rounded[9:0]};
          end
        end
      end else begin
        mant_rounded = rshift_rne_u32({8'd0, mant24}, 13);
        if (mant_rounded >= 32'd2048) begin
          exp_half = exp_half + 1;
          mant_rounded = mant_rounded >> 1;
        end
        if (exp_half >= 31) begin
          o_y_fp16 = {sign, 5'h1F, 10'd0};
        end else begin
          o_y_fp16 = {sign, exp_half[4:0], mant_rounded[9:0]};
        end
      end
    end
  end
endmodule
