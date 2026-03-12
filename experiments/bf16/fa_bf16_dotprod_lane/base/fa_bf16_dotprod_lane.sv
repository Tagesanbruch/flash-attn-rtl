module fa_bf16_dotprod_lane (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        i_clear,
  input  logic        i_hold,
  input  logic        i_valid,
  input  logic [15:0] i_a_bf16,
  input  logic [15:0] i_b_bf16,
  output logic        o_acc_valid,
  output logic [31:0] o_mul_fp32,
  output logic [15:0] o_mul_bf16,
  output logic [31:0] o_acc_fp32,
  output logic [15:0] o_acc_bf16
);
  logic [31:0] mul_fp32;
  logic [15:0] mul_bf16;

  fa_bf16_mul_lane u_mul_lane (
    .i_a_bf16(i_a_bf16),
    .i_b_bf16(i_b_bf16),
    .o_y_fp32(mul_fp32),
    .o_y_bf16(mul_bf16)
  );

  fa_fp32_accum u_accum (
    .clk(clk),
    .rst_n(rst_n),
    .i_clear(i_clear),
    .i_hold(i_hold),
    .i_valid(i_valid),
    .i_x_fp32(mul_fp32),
    .o_valid(o_acc_valid),
    .o_acc_fp32(o_acc_fp32)
  );

  fa_fp32_to_bf16 u_acc_downcast (
    .i_x_fp32(o_acc_fp32),
    .o_y_bf16(o_acc_bf16)
  );

  assign o_mul_fp32 = mul_fp32;
  assign o_mul_bf16 = mul_bf16;
endmodule
