module fa_fp32_add (
  input  logic [31:0] i_a_fp32,
  input  logic [31:0] i_b_fp32,
  output logic [31:0] o_y_fp32
);
  function automatic [26:0] shift_right_sticky_27(
    input logic [26:0] value,
    input integer      shamt
  );
    logic [26:0] shifted;
    logic        sticky;
    logic [26:0] lost_mask;
    begin
      shifted = 27'd0;
      sticky = 1'b0;
      lost_mask = 27'd0;
      if (shamt <= 0) begin
        shifted = value;
      end else if (shamt >= 27) begin
        shifted = 27'd0;
        shifted[0] = |value;
      end else begin
        shifted = value >> shamt;
        lost_mask = (27'd1 << shamt) - 27'd1;
        sticky = |(value & lost_mask);
        shifted[0] = shifted[0] | sticky;
      end
      shift_right_sticky_27 = shifted;
    end
  endfunction

  logic        a_sign;
  logic [7:0]  a_exp;
  logic [22:0] a_frac;
  logic        b_sign;
  logic [7:0]  b_exp;
  logic [22:0] b_frac;

  logic        a_is_nan;
  logic        b_is_nan;
  logic        a_is_inf;
  logic        b_is_inf;
  logic        a_is_zero;
  logic        b_is_zero;

  logic [7:0]  a_exp_eff;
  logic [7:0]  b_exp_eff;
  logic [23:0] a_sig;
  logic [23:0] b_sig;

  logic        large_sign;
  logic        small_sign;
  logic [7:0]  large_exp_eff;
  logic [7:0]  small_exp_eff;
  logic [23:0] large_sig;
  logic [23:0] small_sig;

  logic [26:0] large_sig_ext;
  logic [26:0] small_sig_ext;
  logic [26:0] small_sig_shifted;
  logic [27:0] add_sum_ext;
  logic [26:0] sig_work;
  logic [7:0]  exp_work;
  logic        sign_work;
  logic [22:0] frac_work;
  logic [24:0] round_tmp;
  logic [23:0] sub_round_tmp;
  integer      shift_amt;

  always_comb begin
    a_sign = i_a_fp32[31];
    a_exp  = i_a_fp32[30:23];
    a_frac = i_a_fp32[22:0];
    b_sign = i_b_fp32[31];
    b_exp  = i_b_fp32[30:23];
    b_frac = i_b_fp32[22:0];

    a_is_nan  = (a_exp == 8'hFF) && (a_frac != 23'd0);
    b_is_nan  = (b_exp == 8'hFF) && (b_frac != 23'd0);
    a_is_inf  = (a_exp == 8'hFF) && (a_frac == 23'd0);
    b_is_inf  = (b_exp == 8'hFF) && (b_frac == 23'd0);
    a_is_zero = (a_exp == 8'd0) && (a_frac == 23'd0);
    b_is_zero = (b_exp == 8'd0) && (b_frac == 23'd0);

    a_exp_eff = (a_exp == 8'd0) ? 8'd1 : a_exp;
    b_exp_eff = (b_exp == 8'd0) ? 8'd1 : b_exp;
    a_sig = (a_exp == 8'd0) ? {1'b0, a_frac} : {1'b1, a_frac};
    b_sig = (b_exp == 8'd0) ? {1'b0, b_frac} : {1'b1, b_frac};

    if ((a_exp_eff > b_exp_eff) || ((a_exp_eff == b_exp_eff) && (a_sig >= b_sig))) begin
      large_sign = a_sign;
      large_exp_eff = a_exp_eff;
      large_sig = a_sig;
      small_sign = b_sign;
      small_exp_eff = b_exp_eff;
      small_sig = b_sig;
    end else begin
      large_sign = b_sign;
      large_exp_eff = b_exp_eff;
      large_sig = b_sig;
      small_sign = a_sign;
      small_exp_eff = a_exp_eff;
      small_sig = a_sig;
    end

    large_sig_ext = {large_sig, 3'b000};
    small_sig_ext = {small_sig, 3'b000};
    shift_amt = large_exp_eff - small_exp_eff;
    small_sig_shifted = shift_right_sticky_27(small_sig_ext, shift_amt);

    o_y_fp32 = 32'd0;
    sig_work = 27'd0;
    exp_work = 8'd0;
    sign_work = 1'b0;
    frac_work = 23'd0;
    add_sum_ext = 28'd0;
    round_tmp = 25'd0;
    sub_round_tmp = 24'd0;

    if (a_is_nan || b_is_nan) begin
      o_y_fp32 = 32'h7FC0_0000;
    end else if (a_is_inf && b_is_inf && (a_sign != b_sign)) begin
      o_y_fp32 = 32'h7FC0_0000;
    end else if (a_is_inf) begin
      o_y_fp32 = {a_sign, 8'hFF, 23'd0};
    end else if (b_is_inf) begin
      o_y_fp32 = {b_sign, 8'hFF, 23'd0};
    end else if (a_is_zero && b_is_zero) begin
      o_y_fp32 = {(a_sign & b_sign), 31'd0};
    end else begin
      sign_work = large_sign;
      exp_work = large_exp_eff;

      if (large_sign == small_sign) begin
        add_sum_ext = {1'b0, large_sig_ext} + {1'b0, small_sig_shifted};
        if (add_sum_ext[27]) begin
          sig_work = add_sum_ext[27:1];
          sig_work[0] = sig_work[0] | add_sum_ext[0];
          exp_work = large_exp_eff + 8'd1;
        end else begin
          sig_work = add_sum_ext[26:0];
        end
      end else begin
        sig_work = large_sig_ext - small_sig_shifted;
        if (sig_work == 27'd0) begin
          sign_work = 1'b0;
          exp_work = 8'd0;
        end else begin
          while ((sig_work[26] == 1'b0) && (exp_work > 8'd1)) begin
            sig_work = sig_work << 1;
            exp_work = exp_work - 8'd1;
          end
        end
      end

      if (sig_work == 27'd0) begin
        o_y_fp32 = {sign_work, 31'd0};
      end else if (sig_work[26]) begin
        round_tmp = {1'b0, sig_work[26:3]};
        if (sig_work[2] && (sig_work[1] || sig_work[0] || sig_work[3])) begin
          round_tmp = round_tmp + 25'd1;
        end

        if (round_tmp[24]) begin
          if (exp_work >= 8'hFE) begin
            o_y_fp32 = {sign_work, 8'hFF, 23'd0};
          end else begin
            o_y_fp32 = {sign_work, exp_work + 8'd1, 23'd0};
          end
        end else if (exp_work >= 8'hFF) begin
          o_y_fp32 = {sign_work, 8'hFF, 23'd0};
        end else begin
          frac_work = round_tmp[22:0];
          if (exp_work == 8'd1 && round_tmp[23] == 1'b0) begin
            sub_round_tmp = {1'b0, sig_work[25:3]};
            if (sig_work[2] && (sig_work[1] || sig_work[0] || sig_work[3])) begin
              sub_round_tmp = sub_round_tmp + 24'd1;
            end
            if (sub_round_tmp[23]) begin
              o_y_fp32 = {sign_work, 8'd1, 23'd0};
            end else begin
              o_y_fp32 = {sign_work, 8'd0, sub_round_tmp[22:0]};
            end
          end else begin
            o_y_fp32 = {sign_work, exp_work, frac_work};
          end
        end
      end else begin
        sub_round_tmp = {1'b0, sig_work[25:3]};
        if (sig_work[2] && (sig_work[1] || sig_work[0] || sig_work[3])) begin
          sub_round_tmp = sub_round_tmp + 24'd1;
        end
        if (sub_round_tmp[23]) begin
          o_y_fp32 = {sign_work, 8'd1, 23'd0};
        end else begin
          o_y_fp32 = {sign_work, 8'd0, sub_round_tmp[22:0]};
        end
      end
    end
  end
endmodule
