module fa_fp32_mul_q16 (
  input  logic [31:0] i_a_fp32,
  input  logic [31:0] i_b_fp32,
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

  function automatic signed [31:0] fp32_to_q16_16(input logic [31:0] x_bits);
    logic        sign;
    logic [7:0]  exp_fp32;
    logic [22:0] frac_fp32;
    logic [23:0] sig24;
    integer      exp_unbiased;
    integer      shift_i;
    logic [63:0] tmp64;
    logic [31:0] mag_q16_16;
    begin
      sign = x_bits[31];
      exp_fp32 = x_bits[30:23];
      frac_fp32 = x_bits[22:0];
      mag_q16_16 = 32'd0;

      if ((exp_fp32 == 8'd0) && (frac_fp32 == 23'd0)) begin
        fp32_to_q16_16 = 32'sd0;
      end else begin
        sig24 = (exp_fp32 == 8'd0) ? {1'b0, frac_fp32} : {1'b1, frac_fp32};
        exp_unbiased = (exp_fp32 == 8'd0) ? -126 : ($signed({1'b0, exp_fp32}) - 127);
        shift_i = exp_unbiased - 7;

        if (shift_i >= 0) begin
          tmp64 = {40'd0, sig24} << shift_i;
          if (tmp64 > 64'h0000_0000_7FFF_FFFF) begin
            mag_q16_16 = 32'h7FFF_FFFF;
          end else begin
            mag_q16_16 = tmp64[31:0];
          end
        end else begin
          mag_q16_16 = round_shift_right_rne_32({8'd0, sig24}, -shift_i);
        end

        fp32_to_q16_16 = sign ? -$signed(mag_q16_16) : $signed(mag_q16_16);
      end
    end
  endfunction

  function automatic [31:0] q16_16_to_fp32(input logic signed [31:0] q_val);
    logic        sign;
    logic [31:0] mag_q;
    integer      msb_idx;
    integer      exp_unbiased;
    integer      shift_i;
    logic [24:0] sig25;
    logic [23:0] sig24;
    logic [7:0]  exp_fp32;
    begin
      sign = q_val[31];
      mag_q = sign ? $unsigned(-q_val) : $unsigned(q_val);
      if (mag_q == 32'd0) begin
        q16_16_to_fp32 = {sign, 31'd0};
      end else begin
        msb_idx = -1;
        for (int i = 31; i >= 0; i--) begin
          if ((msb_idx == -1) && mag_q[i]) begin
            msb_idx = i;
          end
        end
        exp_unbiased = msb_idx - 16;
        shift_i = msb_idx - 23;
        if (shift_i > 0) begin
          sig25 = {1'b0, round_shift_right_rne_32(mag_q, shift_i)[23:0]};
        end else begin
          sig25 = {1'b0, (mag_q << (23 - msb_idx))};
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

  logic signed [31:0] a_q16_16;
  logic signed [31:0] b_q16_16;
  logic signed [63:0] prod_q32_32;
  logic signed [63:0] prod_round_bias;
  logic signed [31:0] prod_q16_16;

  always_comb begin
    a_q16_16 = fp32_to_q16_16(i_a_fp32);
    b_q16_16 = fp32_to_q16_16(i_b_fp32);
    prod_q32_32 = a_q16_16 * b_q16_16;
    prod_round_bias = prod_q32_32;
    if (prod_q32_32 >= 64'sd0) begin
      prod_round_bias = prod_q32_32 + 64'sd32768;
    end else begin
      prod_round_bias = prod_q32_32 - 64'sd32768;
    end
    prod_q16_16 = prod_round_bias >>> 16;
    o_y_fp32 = q16_16_to_fp32(prod_q16_16);
  end
endmodule
