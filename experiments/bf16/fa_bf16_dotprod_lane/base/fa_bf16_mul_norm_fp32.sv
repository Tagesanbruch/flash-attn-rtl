module fa_bf16_mul_norm_fp32 (
  input  logic        i_sign,
  input  logic signed [10:0] i_exp_unbiased,
  input  logic [15:0] i_mant_prod,
  input  logic        i_is_zero,
  input  logic        i_is_inf,
  input  logic        i_is_nan,
  output logic [31:0] o_y_fp32
);
  integer      msb_idx;
  integer      exp_norm_i;
  integer      shift_i;
  logic [23:0] sig24;
  logic [23:0] sub_frac;
  logic        round_guard;
  logic        round_sticky;
  logic [55:0] shifted_tmp;
  logic [55:0] sig_ext;

  always_comb begin
    o_y_fp32     = 32'd0;
    msb_idx      = -1;
    exp_norm_i   = 0;
    shift_i      = 0;
    sig24        = 24'd0;
    sub_frac     = 24'd0;
    round_guard  = 1'b0;
    round_sticky = 1'b0;
    shifted_tmp  = 56'd0;
    sig_ext      = 56'd0;

    if (i_is_nan) begin
      o_y_fp32 = {i_sign, 8'hFF, 23'h400000};
    end else if (i_is_inf) begin
      o_y_fp32 = {i_sign, 8'hFF, 23'd0};
    end else if (i_is_zero || (i_mant_prod == 16'd0)) begin
      o_y_fp32 = {i_sign, 31'd0};
    end else begin
      for (int i = 15; i >= 0; i--) begin
        if ((msb_idx == -1) && i_mant_prod[i]) begin
          msb_idx = i;
        end
      end

      exp_norm_i = $signed(i_exp_unbiased) + msb_idx - 14;
      sig24 = {8'd0, i_mant_prod} << (23 - msb_idx);

      if (exp_norm_i > 127) begin
        o_y_fp32 = {i_sign, 8'hFF, 23'd0};
      end else if (exp_norm_i >= -126) begin
        o_y_fp32 = {i_sign, exp_norm_i[7:0] + 8'd127, sig24[22:0]};
      end else begin
        shift_i = -126 - exp_norm_i;
        sig_ext = {32'd0, sig24};

        if (shift_i >= 56) begin
          sub_frac = 24'd0;
        end else begin
          shifted_tmp = sig_ext >> shift_i;
          sub_frac = shifted_tmp[23:0];

          if (shift_i > 0) begin
            round_guard = sig_ext[shift_i-1];
          end
          if (shift_i > 1) begin
            round_sticky = |(sig_ext & ((56'd1 << (shift_i - 1)) - 56'd1));
          end
          if (round_guard && (round_sticky || sub_frac[0])) begin
            sub_frac = sub_frac + 24'd1;
          end
        end

        if (sub_frac >= 24'h800000) begin
          o_y_fp32 = {i_sign, 8'd1, 23'd0};
        end else begin
          o_y_fp32 = {i_sign, 8'd0, sub_frac[22:0]};
        end
      end
    end
  end
endmodule
