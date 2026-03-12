module fa_bf16_mul_prealign (
  input  logic [15:0] i_a_bf16,
  input  logic [15:0] i_b_bf16,
  output logic        o_sign,
  output logic signed [10:0] o_exp_unbiased,
  output logic [15:0] o_mant_prod,
  output logic        o_is_zero,
  output logic        o_is_inf,
  output logic        o_is_nan,
  output logic        o_a_subnorm,
  output logic        o_b_subnorm
);
  logic        a_sign;
  logic [7:0]  a_exp;
  logic [6:0]  a_frac;
  logic        b_sign;
  logic [7:0]  b_exp;
  logic [6:0]  b_frac;
  logic        a_is_zero;
  logic        b_is_zero;
  logic        a_is_inf;
  logic        b_is_inf;
  logic        a_is_nan;
  logic        b_is_nan;
  logic signed [10:0] a_exp_eff;
  logic signed [10:0] b_exp_eff;
  logic [7:0]  a_mant;
  logic [7:0]  b_mant;

  always_comb begin
    a_sign = i_a_bf16[15];
    a_exp  = i_a_bf16[14:7];
    a_frac = i_a_bf16[6:0];
    b_sign = i_b_bf16[15];
    b_exp  = i_b_bf16[14:7];
    b_frac = i_b_bf16[6:0];

    a_is_zero   = (a_exp == 8'd0) && (a_frac == 7'd0);
    b_is_zero   = (b_exp == 8'd0) && (b_frac == 7'd0);
    a_is_inf    = (a_exp == 8'hFF) && (a_frac == 7'd0);
    b_is_inf    = (b_exp == 8'hFF) && (b_frac == 7'd0);
    a_is_nan    = (a_exp == 8'hFF) && (a_frac != 7'd0);
    b_is_nan    = (b_exp == 8'hFF) && (b_frac != 7'd0);
    o_a_subnorm = (a_exp == 8'd0) && (a_frac != 7'd0);
    o_b_subnorm = (b_exp == 8'd0) && (b_frac != 7'd0);

    a_exp_eff = o_a_subnorm ? -11'sd126 : $signed({3'd0, a_exp}) - 11'sd127;
    b_exp_eff = o_b_subnorm ? -11'sd126 : $signed({3'd0, b_exp}) - 11'sd127;
    a_mant    = o_a_subnorm ? {1'b0, a_frac} : {1'b1, a_frac};
    b_mant    = o_b_subnorm ? {1'b0, b_frac} : {1'b1, b_frac};

    o_sign         = a_sign ^ b_sign;
    o_exp_unbiased = 11'sd0;
    o_mant_prod    = 16'd0;
    o_is_zero      = 1'b0;
    o_is_inf       = 1'b0;
    o_is_nan       = 1'b0;

    if (a_is_nan || b_is_nan || ((a_is_inf || b_is_inf) && (a_is_zero || b_is_zero))) begin
      o_is_nan = 1'b1;
    end else if (a_is_inf || b_is_inf) begin
      o_is_inf = 1'b1;
    end else if (a_is_zero || b_is_zero) begin
      o_is_zero = 1'b1;
    end else begin
      o_exp_unbiased = a_exp_eff + b_exp_eff;
      o_mant_prod    = a_mant * b_mant;
    end
  end
endmodule
