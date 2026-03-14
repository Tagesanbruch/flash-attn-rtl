module fa_fp8_mma_uop_engine (
  input  logic                i_clk,
  input  logic                i_rst_n,
  input  logic                i_valid,
  output logic                o_ready,
  input  logic [7:0]          i_a_fp8,
  input  logic [7:0]          i_b_fp8,
  input  logic signed [31:0]  i_acc_q8_11,
  input  logic signed [15:0]  i_scale_q1_14,
  input  logic [1:0]          i_round_mode,
  input  logic                i_saturate_en,
  output logic                o_valid,
  input  logic                i_ready,
  output logic signed [31:0]  o_res_q8_11
);
  logic               out_valid_r;
  logic signed [31:0] out_res_r;

  function automatic signed [15:0] fp8_e4m3_to_q4_11(input logic [7:0] fp8);
    logic sign;
    logic [3:0] exp;
    logic [2:0] frac;
    logic signed [31:0] mag;
    begin
      sign = fp8[7];
      exp = fp8[6:3];
      frac = fp8[2:0];
      if (exp == 4'd0) begin
        mag = $signed({1'b0, frac}) <<< 2;
      end else if (exp == 4'hF) begin
        mag = 32'sd32767;
      end else begin
        mag = $signed({1'b0, 3'd0, 1'b1, frac}) <<< (exp + 1);
        if (mag > 32'sd32767) begin
          mag = 32'sd32767;
        end
      end
      if (sign) begin
        fp8_e4m3_to_q4_11 = -mag[15:0];
      end else begin
        fp8_e4m3_to_q4_11 = mag[15:0];
      end
    end
  endfunction

  function automatic signed [55:0] round_shift_right_56(
    input signed [55:0] v,
    input int sh,
    input logic [1:0] round_mode
  );
    logic signed [55:0] t;
    begin
      t = v;
      if (sh <= 0) begin
        round_shift_right_56 = v;
      end else begin
        if (round_mode == 2'd1) begin
          if (v >= 0) begin
            t = v + (56'sd1 <<< (sh - 1));
          end else begin
            t = v - (56'sd1 <<< (sh - 1));
          end
        end
        round_shift_right_56 = t >>> sh;
      end
    end
  endfunction

  logic signed [15:0] a_q4_11;
  logic signed [15:0] b_q4_11;
  logic signed [39:0] prod_q8_22;
  logic signed [39:0] dot_q8_11;
  logic signed [39:0] sum_q8_11;
  logic signed [55:0] scaled_q9_25;
  logic signed [55:0] scaled_q8_11;
  logic signed [31:0] next_res;

  always_comb begin
    a_q4_11 = fp8_e4m3_to_q4_11(i_a_fp8);
    b_q4_11 = fp8_e4m3_to_q4_11(i_b_fp8);
    prod_q8_22 = $signed(a_q4_11) * $signed(b_q4_11);
    dot_q8_11 = prod_q8_22 >>> 11;
    sum_q8_11 = dot_q8_11 + $signed(i_acc_q8_11);

    scaled_q9_25 = $signed(sum_q8_11) * $signed(i_scale_q1_14);
    scaled_q8_11 = round_shift_right_56(scaled_q9_25, 14, i_round_mode);

    if (i_saturate_en) begin
      if (scaled_q8_11 > 56'sd2147483647) begin
        next_res = 32'sd2147483647;
      end else if (scaled_q8_11 < -56'sd2147483648) begin
        next_res = -32'sd2147483648;
      end else begin
        next_res = scaled_q8_11[31:0];
      end
    end else begin
      next_res = scaled_q8_11[31:0];
    end
  end

  assign o_ready = (~out_valid_r) | i_ready;
  assign o_valid = out_valid_r;
  assign o_res_q8_11 = out_res_r;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      out_valid_r <= 1'b0;
      out_res_r <= 32'sd0;
    end else begin
      if (o_ready) begin
        out_valid_r <= i_valid;
        if (i_valid) begin
          out_res_r <= next_res;
        end
      end
    end
  end
endmodule
