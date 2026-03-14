module fa_fp8_e4m3_to_fixed16_cfg (
  input  logic [7:0] i_fp8,
  input  logic [1:0] i_round_mode,
  input  logic       i_saturate_en,
  input  logic [3:0] i_out_frac_bits,
  output logic signed [15:0] o_fixed,
  output logic              o_is_nan,
  output logic              o_is_inf,
  output logic              o_is_zero
);
  logic sign;
  logic [3:0] exp;
  logic [2:0] frac;

  logic signed [31:0] val_q4_11;
  logic signed [31:0] quant_q;
  logic signed [31:0] rounded;
  logic signed [31:0] clamp_q;
  logic [3:0] frac_bits;
  logic [4:0] sh;

  always_comb begin
    sign = i_fp8[7];
    exp = i_fp8[6:3];
    frac = i_fp8[2:0];
    frac_bits = (i_out_frac_bits > 4'd11) ? 4'd11 : i_out_frac_bits;
    sh = 5'd0;
    rounded = 32'sd0;
    quant_q = 32'sd0;
    clamp_q = 32'sd0;
    o_fixed = 16'sd0;

    o_is_nan = 1'b0;
    o_is_inf = 1'b0;
    o_is_zero = 1'b0;

    if ((exp == 4'd0) && (frac == 3'd0)) begin
      val_q4_11 = 32'sd0;
      o_is_zero = 1'b1;
    end else if (exp == 4'd0) begin
      // Subnormal: value = frac * 2^-9, converted to Q4.11 => frac * 2^2.
      val_q4_11 = $signed({1'b0, frac}) <<< 2;
      if (sign) begin
        val_q4_11 = -val_q4_11;
      end
    end else if (exp == 4'hF) begin
      // For Inf/NaN, map to finite max magnitude with sign and expose flags.
      o_is_inf = (frac == 3'd0);
      o_is_nan = (frac != 3'd0);
      if (sign) begin
        val_q4_11 = -32'sd32767;
      end else begin
        val_q4_11 = 32'sd32767;
      end
    end else begin
      // Normal: value = (1 + frac/8) * 2^(exp-7), converted to Q4.11.
      val_q4_11 = $signed({1'b0, 3'd0, 1'b1, frac}) <<< (exp + 1);
      if (sign) begin
        val_q4_11 = -val_q4_11;
      end
    end

    if (frac_bits < 4'd11) begin
      sh = 5'(4'd11 - frac_bits);
      rounded = val_q4_11;
      // round_mode: 0=trunc, 1=nearest-away-from-zero.
      if ((i_round_mode == 2'd1) && (sh != 0)) begin
        if (val_q4_11 >= 32'sd0) begin
          rounded = val_q4_11 + (32'sd1 <<< (sh - 1));
        end else begin
          rounded = val_q4_11 - (32'sd1 <<< (sh - 1));
        end
      end
      quant_q = rounded >>> sh;
    end else if (frac_bits > 4'd11) begin
      sh = 5'(frac_bits - 4'd11);
      quant_q = val_q4_11 <<< sh;
    end else begin
      quant_q = val_q4_11;
    end

    if (i_saturate_en) begin
      if (quant_q > 32'sd32767) begin
        clamp_q = 32'sd32767;
      end else if (quant_q < -32'sd32768) begin
        clamp_q = -32'sd32768;
      end else begin
        clamp_q = quant_q;
      end
      o_fixed = clamp_q[15:0];
    end else begin
      o_fixed = quant_q[15:0];
    end
  end
endmodule
