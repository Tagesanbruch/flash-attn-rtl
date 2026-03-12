module fa_fp32_exp2_pwl (
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

  function automatic signed [15:0] fp32_to_q8_8(input logic [31:0] x_bits);
    logic        sign;
    logic [7:0]  exp_fp32;
    logic [22:0] frac_fp32;
    logic [23:0] sig24;
    integer      exp_unbiased;
    integer      shift_i;
    logic [63:0] tmp64;
    logic [31:0] mag_q8_8;
    begin
      sign = x_bits[31];
      exp_fp32 = x_bits[30:23];
      frac_fp32 = x_bits[22:0];
      mag_q8_8 = 32'd0;
      if ((exp_fp32 == 8'd0) && (frac_fp32 == 23'd0)) begin
        fp32_to_q8_8 = 16'sd0;
      end else begin
        sig24 = (exp_fp32 == 8'd0) ? {1'b0, frac_fp32} : {1'b1, frac_fp32};
        exp_unbiased = (exp_fp32 == 8'd0) ? -126 : ($signed({1'b0, exp_fp32}) - 127);
        shift_i = exp_unbiased - 15;
        if (shift_i >= 0) begin
          tmp64 = {40'd0, sig24} << shift_i;
          if (tmp64 > 64'd32768) begin
            mag_q8_8 = 32'd32768;
          end else begin
            mag_q8_8 = tmp64[31:0];
          end
        end else begin
          mag_q8_8 = round_shift_right_rne_32({8'd0, sig24}, -shift_i);
        end
        if (sign) begin
          if (mag_q8_8 >= 32'd32768) begin
            fp32_to_q8_8 = -16'sd32768;
          end else begin
            fp32_to_q8_8 = -$signed(mag_q8_8[15:0]);
          end
        end else begin
          if (mag_q8_8 >= 32'd32767) begin
            fp32_to_q8_8 = 16'sd32767;
          end else begin
            fp32_to_q8_8 = $signed(mag_q8_8[15:0]);
          end
        end
      end
    end
  endfunction

  function automatic [31:0] q16_16_to_fp32(input logic [31:0] q_val);
    integer      msb_idx;
    integer      exp_unbiased;
    integer      shift_i;
    logic [24:0] sig25;
    logic [23:0] sig24;
    logic [7:0]  exp_fp32;
    begin
      if (q_val == 32'd0) begin
        q16_16_to_fp32 = 32'd0;
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
          q16_16_to_fp32 = 32'h7F80_0000;
        end else begin
          exp_fp32 = exp_unbiased[7:0] + 8'd127;
          q16_16_to_fp32 = {1'b0, exp_fp32, sig24[22:0]};
        end
      end
    end
  endfunction

  function automatic [17:0] exp2_pwl_point(input logic [4:0] idx);
    begin
      case (idx)
        5'd0: exp2_pwl_point = 18'd65536;
        5'd1: exp2_pwl_point = 18'd68438;
        5'd2: exp2_pwl_point = 18'd71468;
        5'd3: exp2_pwl_point = 18'd74632;
        5'd4: exp2_pwl_point = 18'd77936;
        5'd5: exp2_pwl_point = 18'd81386;
        5'd6: exp2_pwl_point = 18'd84990;
        5'd7: exp2_pwl_point = 18'd88752;
        5'd8: exp2_pwl_point = 18'd92682;
        5'd9: exp2_pwl_point = 18'd96785;
        5'd10: exp2_pwl_point = 18'd101070;
        5'd11: exp2_pwl_point = 18'd105545;
        5'd12: exp2_pwl_point = 18'd110218;
        5'd13: exp2_pwl_point = 18'd115098;
        5'd14: exp2_pwl_point = 18'd120194;
        5'd15: exp2_pwl_point = 18'd125515;
        default: exp2_pwl_point = 18'd131072;
      endcase
    end
  endfunction

  logic        x_sign;
  logic [7:0]  x_exp;
  logic [22:0] x_frac;
  logic        x_is_nan;
  logic        x_is_inf;
  logic signed [15:0] x_q8_8;
  logic signed [15:0] x_clip_q8_8;
  logic signed [15:0] int_part;
  logic [15:0]        mag_q8_8;
  logic [7:0]  frac_part;
  logic [3:0]  seg_idx;
  logic [3:0]  seg_frac;
  logic [17:0] y0_q16_16;
  logic [17:0] y1_q16_16;
  logic [17:0] delta_q16_16;
  logic [21:0] interp_mul;
  logic [17:0] interp_q16_16;
  logic [31:0] res_q16_16;
  logic [63:0] res_q64;
  integer      rshift_i;

  always_comb begin
    x_sign = i_x_fp32[31];
    x_exp  = i_x_fp32[30:23];
    x_frac = i_x_fp32[22:0];
    x_is_nan = (x_exp == 8'hFF) && (x_frac != 23'd0);
    x_is_inf = (x_exp == 8'hFF) && (x_frac == 23'd0);
    x_q8_8 = fp32_to_q8_8(i_x_fp32);
    x_clip_q8_8 = x_q8_8;
    int_part = 16'sd0;
    mag_q8_8 = 16'd0;
    frac_part = 8'd0;
    seg_idx = 4'd0;
    seg_frac = 4'd0;
    y0_q16_16 = 18'd65536;
    y1_q16_16 = 18'd68438;
    delta_q16_16 = 18'd0;
    interp_mul = 22'd0;
    interp_q16_16 = 18'd0;
    res_q16_16 = 32'd0;
    res_q64 = 64'd0;
    rshift_i = 0;

    if (x_is_nan) begin
      o_y_fp32 = 32'h7FC0_0000;
    end else if (x_is_inf && !x_sign) begin
      o_y_fp32 = 32'h7F80_0000;
    end else if (x_is_inf && x_sign) begin
      o_y_fp32 = 32'd0;
    end else begin
      if (x_q8_8 > 16'sd4095) begin
        o_y_fp32 = 32'h7F80_0000;
      end else begin
        if (x_q8_8 < -16'sd4096) begin
          x_clip_q8_8 = -16'sd4096;
        end else begin
          x_clip_q8_8 = x_q8_8;
        end

        if (x_clip_q8_8 >= 16'sd0) begin
          int_part = x_clip_q8_8 >>> 8;
          frac_part = x_clip_q8_8[7:0];
        end else begin
          mag_q8_8 = $unsigned(-x_clip_q8_8);
          if (mag_q8_8[7:0] == 8'd0) begin
            int_part = -$signed({8'd0, mag_q8_8[15:8]});
            frac_part = 8'd0;
          end else begin
            int_part = -$signed({8'd0, mag_q8_8[15:8]}) - 16'sd1;
            frac_part = 8'd0 - mag_q8_8[7:0];
          end
        end

        seg_idx = frac_part[7:4];
        seg_frac = frac_part[3:0];
        y0_q16_16 = exp2_pwl_point({1'b0, seg_idx});
        y1_q16_16 = exp2_pwl_point({1'b0, seg_idx} + 5'd1);
        delta_q16_16 = y1_q16_16 - y0_q16_16;
        interp_mul = delta_q16_16 * seg_frac;
        interp_q16_16 = y0_q16_16 + ((interp_mul + 22'd8) >> 4);

        if (int_part >= 16'sd0) begin
          if (int_part >= 16'sd16) begin
            res_q16_16 = 32'hFFFF_FFFF;
          end else begin
            res_q64 = {46'd0, interp_q16_16} << int_part[4:0];
            if (res_q64 > 64'h0000_0000_FFFF_FFFF) begin
              res_q16_16 = 32'hFFFF_FFFF;
            end else begin
              res_q16_16 = res_q64[31:0];
            end
          end
        end else begin
          rshift_i = -int_part;
          if (rshift_i >= 32) begin
            res_q16_16 = 32'd0;
          end else begin
            res_q16_16 = interp_q16_16 >> rshift_i;
          end
        end

        o_y_fp32 = q16_16_to_fp32(res_q16_16);
      end
    end
  end
endmodule
