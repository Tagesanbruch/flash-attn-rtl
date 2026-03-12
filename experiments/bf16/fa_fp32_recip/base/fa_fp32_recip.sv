module fa_fp32_recip (
  input  logic [31:0] i_x_fp32,
  output logic [31:0] o_y_fp32
);
  function automatic [31:0] round_shift_right_rne_32(
    input logic [31:0] value,
    input integer      shamt
  );
    logic [31:0] base;
    logic        guard;
    logic        sticky;
    logic [31:0] sticky_mask;
    begin
      if (shamt <= 0) begin
        round_shift_right_rne_32 = value;
      end else if (shamt >= 32) begin
        round_shift_right_rne_32 = 32'd0;
        if (|value) begin
          round_shift_right_rne_32 = 32'd1;
        end
      end else begin
        base = value >> shamt;
        guard = value[shamt-1];
        sticky_mask = (shamt > 1) ? ((32'd1 << (shamt - 1)) - 32'd1) : 32'd0;
        sticky = |(value & sticky_mask);
        if (guard && (sticky || base[0])) begin
          round_shift_right_rne_32 = base + 32'd1;
        end else begin
          round_shift_right_rne_32 = base;
        end
      end
    end
  endfunction

  function automatic [31:0] fp32_abs_to_q16_16(input logic [30:0] abs_bits);
    logic [7:0]  exp_fp32;
    logic [22:0] frac_fp32;
    logic [23:0] sig24;
    integer      exp_unbiased;
    integer      shift_i;
    logic [63:0] tmp64;
    logic [31:0] q_val;
    begin
      exp_fp32 = abs_bits[30:23];
      frac_fp32 = abs_bits[22:0];
      q_val = 32'd0;

      if ((exp_fp32 == 8'd0) && (frac_fp32 == 23'd0)) begin
        q_val = 32'd0;
      end else begin
        sig24 = (exp_fp32 == 8'd0) ? {1'b0, frac_fp32} : {1'b1, frac_fp32};
        exp_unbiased = (exp_fp32 == 8'd0) ? -126 : ($signed({1'b0, exp_fp32}) - 127);
        shift_i = exp_unbiased - 7;

        if (shift_i >= 0) begin
          tmp64 = {40'd0, sig24} << shift_i;
          if (tmp64 > 64'h0000_0000_FFFF_FFFF) begin
            q_val = 32'hFFFF_FFFF;
          end else begin
            q_val = tmp64[31:0];
          end
        end else begin
          q_val = round_shift_right_rne_32({8'd0, sig24}, -shift_i);
        end
      end

      fp32_abs_to_q16_16 = q_val;
    end
  endfunction

  function automatic [31:0] q16_16_to_fp32(
    input logic        sign,
    input logic [31:0] q_val
  );
    integer      msb_idx;
    integer      exp_unbiased;
    integer      shift_i;
    logic [24:0] sig25;
    logic [23:0] sig24;
    logic [7:0]  exp_fp32;
    begin
      if (q_val == 32'd0) begin
        q16_16_to_fp32 = {sign, 31'd0};
      end else begin
        msb_idx = -1;
        for (int i = 31; i >= 0; i--) begin
          if ((msb_idx == -1) && q_val[i]) begin
            msb_idx = i;
          end
        end

        exp_unbiased = msb_idx - 16;
        shift_i = msb_idx - 23;
        if (shift_i > 0) begin
          sig25 = {1'b0, round_shift_right_rne_32(q_val, shift_i)[23:0]};
        end else begin
          sig25 = {1'b0, (q_val << (23 - msb_idx))};
        end

        if (sig25[24]) begin
          sig24 = sig25[24:1];
          exp_unbiased = exp_unbiased + 1;
        end else begin
          sig24 = sig25[23:0];
        end

        if (exp_unbiased > 127) begin
          q16_16_to_fp32 = {sign, 8'hFF, 23'd0};
        end else begin
          exp_fp32 = exp_unbiased[7:0] + 8'd127;
          q16_16_to_fp32 = {sign, exp_fp32, sig24[22:0]};
        end
      end
    end
  endfunction

  logic        x_sign;
  logic [7:0]  x_exp;
  logic [22:0] x_frac;
  logic        x_is_nan;
  logic        x_is_inf;
  logic        x_is_zero;
  logic [31:0] x_q16_16;
  logic [63:0] recip_num;
  logic [63:0] recip_q64;
  logic [31:0] recip_q16_16;

  always_comb begin
    x_sign = i_x_fp32[31];
    x_exp  = i_x_fp32[30:23];
    x_frac = i_x_fp32[22:0];
    x_is_nan = (x_exp == 8'hFF) && (x_frac != 23'd0);
    x_is_inf = (x_exp == 8'hFF) && (x_frac == 23'd0);
    x_is_zero = (x_exp == 8'd0) && (x_frac == 23'd0);
    x_q16_16 = 32'd0;
    recip_num = 64'h0000_0001_0000_0000;
    recip_q64 = 64'd0;
    recip_q16_16 = 32'd0;

    if (x_is_nan) begin
      o_y_fp32 = 32'h7FC0_0000;
    end else if (x_is_inf) begin
      o_y_fp32 = {x_sign, 31'd0};
    end else if (x_is_zero) begin
      o_y_fp32 = {x_sign, 8'hFF, 23'd0};
    end else begin
      x_q16_16 = fp32_abs_to_q16_16(i_x_fp32[30:0]);
      if (x_q16_16 == 32'd0) begin
        o_y_fp32 = {x_sign, 8'hFF, 23'd0};
      end else begin
      recip_q64 = recip_num / {32'd0, x_q16_16};
      if (recip_q64 > 64'h0000_0000_FFFF_FFFF) begin
        recip_q16_16 = 32'hFFFF_FFFF;
      end else begin
        recip_q16_16 = recip_q64[31:0];
      end
        o_y_fp32 = q16_16_to_fp32(x_sign, recip_q16_16);
      end
    end
  end
endmodule
