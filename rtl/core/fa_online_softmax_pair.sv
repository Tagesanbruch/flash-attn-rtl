module fa_online_softmax_pair #(
  parameter int D = 64
) (
  i_row1_valid,
  i_neg_large_q8_8,
  i_score0,
  i_score1,
  i_m_old0,
  i_m_old1,
  i_l_old0,
  i_l_old1,
  i_acc_old0_flat,
  i_acc_old1_flat,
  i_v_row_flat,
  o_m_new0,
  o_m_new1,
  o_l_new0,
  o_l_new1,
  o_exp_old0,
  o_exp_new0,
  o_exp_old1,
  o_exp_new1,
  o_acc_new0_flat,
  o_acc_new1_flat
);

  input  logic                     i_row1_valid;
  input  logic signed [15:0]       i_neg_large_q8_8;
  input  logic signed [15:0]       i_score0;
  input  logic signed [15:0]       i_score1;
  input  logic signed [15:0]       i_m_old0;
  input  logic signed [15:0]       i_m_old1;
  input  logic [31:0]              i_l_old0;
  input  logic [31:0]              i_l_old1;
  input  logic [D*64-1:0]          i_acc_old0_flat;
  input  logic [D*64-1:0]          i_acc_old1_flat;
  input  logic [D*16-1:0]          i_v_row_flat;
  output logic signed [15:0]       o_m_new0;
  output logic signed [15:0]       o_m_new1;
  output logic [31:0]              o_l_new0;
  output logic [31:0]              o_l_new1;
  output logic [15:0]              o_exp_old0;
  output logic [15:0]              o_exp_new0;
  output logic [15:0]              o_exp_old1;
  output logic [15:0]              o_exp_new1;
  output logic [D*64-1:0]          o_acc_new0_flat;
  output logic [D*64-1:0]          o_acc_new1_flat;

  logic signed [15:0] exp_diff_old_in0, exp_diff_new_in0;
  logic signed [15:0] exp_diff_old_in1, exp_diff_new_in1;
  logic [63:0]        l_scaled_wide0;
  logic [63:0]        l_scaled_wide1;
  logic [31:0]        l_scaled0;
  logic [31:0]        l_scaled1;
  logic [31:0]        l_term0;
  logic [31:0]        l_term1;
  logic [31:0]        l_new_val0;
  logic [31:0]        l_new_val1;

  function automatic logic signed [63:0] lane64(
    input logic [D*64-1:0] vec,
    input int              idx
  );
    lane64 = $signed(vec[idx*64 +: 64]);
  endfunction

  function automatic logic signed [15:0] lane16(
    input logic [D*16-1:0] vec,
    input int              idx
  );
    lane16 = $signed(vec[idx*16 +: 16]);
  endfunction

  fa_exp_pwl_8seg_q1_15 u_exp_old0 (.i_x_q8_8(exp_diff_old_in0), .o_exp_q1_15(o_exp_old0));
  fa_exp_pwl_8seg_q1_15 u_exp_new0 (.i_x_q8_8(exp_diff_new_in0), .o_exp_q1_15(o_exp_new0));
  fa_exp_pwl_8seg_q1_15 u_exp_old1 (.i_x_q8_8(exp_diff_old_in1), .o_exp_q1_15(o_exp_old1));
  fa_exp_pwl_8seg_q1_15 u_exp_new1 (.i_x_q8_8(exp_diff_new_in1), .o_exp_q1_15(o_exp_new1));

  always_comb begin
    if (i_score0 > i_m_old0)
      o_m_new0 = i_score0;
    else
      o_m_new0 = i_m_old0;

    exp_diff_old_in0 = i_m_old0 - o_m_new0;
    exp_diff_new_in0 = i_score0 - o_m_new0;
    l_scaled_wide0 = i_l_old0 * o_exp_old0;
    l_scaled0 = l_scaled_wide0[46:15];
    l_term0 = {15'd0, o_exp_new0, 1'b0};
    l_new_val0 = l_scaled0 + l_term0;
    o_l_new0 = (l_new_val0 == 32'd0) ? 32'd1 : l_new_val0;

    if (i_row1_valid) begin
      if (i_score1 > i_m_old1)
        o_m_new1 = i_score1;
      else
        o_m_new1 = i_m_old1;

      exp_diff_old_in1 = i_m_old1 - o_m_new1;
      exp_diff_new_in1 = i_score1 - o_m_new1;
      l_scaled_wide1 = i_l_old1 * o_exp_old1;
      l_scaled1 = l_scaled_wide1[46:15];
      l_term1 = {15'd0, o_exp_new1, 1'b0};
      l_new_val1 = l_scaled1 + l_term1;
      o_l_new1 = (l_new_val1 == 32'd0) ? 32'd1 : l_new_val1;
    end else begin
      o_m_new1 = i_neg_large_q8_8;
      exp_diff_old_in1 = 16'sd0;
      exp_diff_new_in1 = 16'sd0;
      l_scaled_wide1 = 64'd0;
      l_scaled1 = 32'd0;
      l_term1 = 32'd0;
      l_new_val1 = 32'd0;
      o_l_new1 = 32'd1;
    end

    for (int k = 0; k < D; k++) begin
      logic signed [95:0] acc_sc;
      logic signed [63:0] acc_old_sc;
      logic signed [33:0] pv_mul;
      logic signed [63:0] pv_term;

      acc_sc = lane64(i_acc_old0_flat, k) * $signed({1'b0, o_exp_old0});
      acc_old_sc = acc_sc[78:15];
      pv_mul = $signed({1'b0, o_exp_new0}) * lane16(i_v_row_flat, k);
      pv_term = {{30{pv_mul[33]}}, pv_mul[33:0]} <<< 1;
      o_acc_new0_flat[k*64 +: 64] = acc_old_sc + pv_term;

      if (i_row1_valid) begin
        acc_sc = lane64(i_acc_old1_flat, k) * $signed({1'b0, o_exp_old1});
        acc_old_sc = acc_sc[78:15];
        pv_mul = $signed({1'b0, o_exp_new1}) * lane16(i_v_row_flat, k);
        pv_term = {{30{pv_mul[33]}}, pv_mul[33:0]} <<< 1;
        o_acc_new1_flat[k*64 +: 64] = acc_old_sc + pv_term;
      end else begin
        o_acc_new1_flat[k*64 +: 64] = lane64(i_acc_old1_flat, k);
      end
    end
  end
endmodule