module fa_row_norm_vec (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                i_valid,
  input  logic        [31:0]  i_recip_q16_16,
  input  logic signed [31:0]  i_acc0_q16_16,
  input  logic signed [31:0]  i_acc1_q16_16,
  input  logic signed [31:0]  i_acc2_q16_16,
  input  logic signed [31:0]  i_acc3_q16_16,
  input  logic signed [31:0]  i_acc4_q16_16,
  input  logic signed [31:0]  i_acc5_q16_16,
  input  logic signed [31:0]  i_acc6_q16_16,
  input  logic signed [31:0]  i_acc7_q16_16,
  output logic signed [15:0]  o_out0_q8_8,
  output logic signed [15:0]  o_out1_q8_8,
  output logic signed [15:0]  o_out2_q8_8,
  output logic signed [15:0]  o_out3_q8_8,
  output logic signed [15:0]  o_out4_q8_8,
  output logic signed [15:0]  o_out5_q8_8,
  output logic signed [15:0]  o_out6_q8_8,
  output logic signed [15:0]  o_out7_q8_8,
  output logic                o_valid
);
  logic [31:0] recip_reg;
  logic signed [31:0] acc0_reg;
  logic signed [31:0] acc1_reg;
  logic signed [31:0] acc2_reg;
  logic signed [31:0] acc3_reg;
  logic signed [31:0] acc4_reg;
  logic signed [31:0] acc5_reg;
  logic signed [31:0] acc6_reg;
  logic signed [31:0] acc7_reg;
  logic busy;

  function automatic signed [15:0] norm_lane(
    input logic signed [31:0] acc_q16_16,
    input logic        [31:0] recip_q16_16
  );
    logic signed [63:0] norm_mul_q32_32;
    logic signed [31:0] norm_q16_16;
    begin
      norm_mul_q32_32 = acc_q16_16 * $signed({1'b0, recip_q16_16});
      norm_q16_16 = norm_mul_q32_32 >>> 16;
      if (norm_q16_16 > 32'sd32767) begin
        norm_lane = 16'sd32767;
      end else if (norm_q16_16 < -32'sd32768) begin
        norm_lane = -16'sd32768;
      end else begin
        norm_lane = norm_q16_16[15:0];
      end
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      recip_reg <= 32'd0;
      acc0_reg <= 32'sd0;
      acc1_reg <= 32'sd0;
      acc2_reg <= 32'sd0;
      acc3_reg <= 32'sd0;
      acc4_reg <= 32'sd0;
      acc5_reg <= 32'sd0;
      acc6_reg <= 32'sd0;
      acc7_reg <= 32'sd0;
      o_out0_q8_8 <= 16'sd0;
      o_out1_q8_8 <= 16'sd0;
      o_out2_q8_8 <= 16'sd0;
      o_out3_q8_8 <= 16'sd0;
      o_out4_q8_8 <= 16'sd0;
      o_out5_q8_8 <= 16'sd0;
      o_out6_q8_8 <= 16'sd0;
      o_out7_q8_8 <= 16'sd0;
      o_valid <= 1'b0;
      busy <= 1'b0;
    end else begin
      o_valid <= 1'b0;

      if (i_valid) begin
        recip_reg <= i_recip_q16_16;
        acc0_reg <= i_acc0_q16_16;
        acc1_reg <= i_acc1_q16_16;
        acc2_reg <= i_acc2_q16_16;
        acc3_reg <= i_acc3_q16_16;
        acc4_reg <= i_acc4_q16_16;
        acc5_reg <= i_acc5_q16_16;
        acc6_reg <= i_acc6_q16_16;
        acc7_reg <= i_acc7_q16_16;
        busy <= 1'b1;
      end else if (busy) begin
        o_out0_q8_8 <= norm_lane(acc0_reg, recip_reg);
        o_out1_q8_8 <= norm_lane(acc1_reg, recip_reg);
        o_out2_q8_8 <= norm_lane(acc2_reg, recip_reg);
        o_out3_q8_8 <= norm_lane(acc3_reg, recip_reg);
        o_out4_q8_8 <= norm_lane(acc4_reg, recip_reg);
        o_out5_q8_8 <= norm_lane(acc5_reg, recip_reg);
        o_out6_q8_8 <= norm_lane(acc6_reg, recip_reg);
        o_out7_q8_8 <= norm_lane(acc7_reg, recip_reg);
        busy <= 1'b0;
        o_valid <= 1'b1;
      end
    end
  end
endmodule
