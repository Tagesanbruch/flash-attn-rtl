module fa_fp32_accum (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        i_clear,
  input  logic        i_hold,
  input  logic        i_valid,
  input  logic [31:0] i_x_fp32,
  output logic        o_valid,
  output logic [31:0] o_acc_fp32
);
  logic [31:0] acc_base_fp32;
  logic [31:0] acc_next_fp32;
  logic [31:0] acc_reg_fp32;

  assign acc_base_fp32 = i_clear ? 32'd0 : acc_reg_fp32;

  fa_fp32_add u_add (
    .i_a_fp32(acc_base_fp32),
    .i_b_fp32(i_x_fp32),
    .o_y_fp32(acc_next_fp32)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_reg_fp32 <= 32'd0;
      o_valid <= 1'b0;
    end else begin
      o_valid <= 1'b0;

      if (i_clear && !(i_valid && !i_hold)) begin
        acc_reg_fp32 <= 32'd0;
      end

      if (i_valid && !i_hold) begin
        acc_reg_fp32 <= acc_next_fp32;
        o_valid <= 1'b1;
      end
    end
  end

  assign o_acc_fp32 = acc_reg_fp32;
endmodule
