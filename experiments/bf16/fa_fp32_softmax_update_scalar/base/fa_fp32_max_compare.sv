module fa_fp32_max_compare (
  input  logic [31:0] i_a_fp32,
  input  logic [31:0] i_b_fp32,
  output logic        o_a_gt_b,
  output logic        o_a_lt_b,
  output logic        o_a_eq_b,
  output logic        o_unordered,
  output logic [31:0] o_max_fp32
);
  logic        a_sign;
  logic [7:0]  a_exp;
  logic [22:0] a_frac;
  logic        b_sign;
  logic [7:0]  b_exp;
  logic [22:0] b_frac;
  logic        a_is_nan;
  logic        b_is_nan;
  logic        a_is_zero;
  logic        b_is_zero;
  logic [30:0] a_mag;
  logic [30:0] b_mag;

  always_comb begin
    a_sign = i_a_fp32[31];
    a_exp  = i_a_fp32[30:23];
    a_frac = i_a_fp32[22:0];
    b_sign = i_b_fp32[31];
    b_exp  = i_b_fp32[30:23];
    b_frac = i_b_fp32[22:0];

    a_is_nan = (a_exp == 8'hFF) && (a_frac != 23'd0);
    b_is_nan = (b_exp == 8'hFF) && (b_frac != 23'd0);
    a_is_zero = (a_exp == 8'd0) && (a_frac == 23'd0);
    b_is_zero = (b_exp == 8'd0) && (b_frac == 23'd0);
    a_mag = i_a_fp32[30:0];
    b_mag = i_b_fp32[30:0];

    o_a_gt_b = 1'b0;
    o_a_lt_b = 1'b0;
    o_a_eq_b = 1'b0;
    o_unordered = 1'b0;
    o_max_fp32 = 32'd0;

    if (a_is_nan && b_is_nan) begin
      o_unordered = 1'b1;
      o_max_fp32 = 32'h7FC0_0000;
    end else if (a_is_nan) begin
      o_unordered = 1'b1;
      o_max_fp32 = i_b_fp32;
    end else if (b_is_nan) begin
      o_unordered = 1'b1;
      o_max_fp32 = i_a_fp32;
    end else if ((a_is_zero && b_is_zero) || (i_a_fp32 == i_b_fp32)) begin
      o_a_eq_b = 1'b1;
      o_max_fp32 = 32'd0;
      if (!(a_is_zero && b_is_zero)) begin
        o_max_fp32 = i_a_fp32;
      end
    end else if (a_sign != b_sign) begin
      if (a_sign) begin
        o_a_lt_b = 1'b1;
        o_max_fp32 = i_b_fp32;
      end else begin
        o_a_gt_b = 1'b1;
        o_max_fp32 = i_a_fp32;
      end
    end else if (!a_sign) begin
      if (a_mag > b_mag) begin
        o_a_gt_b = 1'b1;
        o_max_fp32 = i_a_fp32;
      end else begin
        o_a_lt_b = 1'b1;
        o_max_fp32 = i_b_fp32;
      end
    end else begin
      if (a_mag < b_mag) begin
        o_a_gt_b = 1'b1;
        o_max_fp32 = i_a_fp32;
      end else begin
        o_a_lt_b = 1'b1;
        o_max_fp32 = i_b_fp32;
      end
    end
  end
endmodule
