module fa_qk_dotprod_slice #(
  parameter int D        = 64,
  parameter int DP_LANES = 32
) (
  input  logic signed [15:0] i_q_row0 [D],
  input  logic signed [15:0] i_q_row1 [D],
  input  logic               i_row1_valid,
  input  logic signed [15:0] i_k_row  [D],
  input  logic [$clog2(D)-1:0] i_chunk_idx,
  output logic signed [39:0] o_partial_sum0,
  output logic signed [39:0] o_partial_sum1
);

  always_comb begin
    int d_idx;
    o_partial_sum0 = '0;
    o_partial_sum1 = '0;
    for (int lane = 0; lane < DP_LANES; lane++) begin
      d_idx = i_chunk_idx * DP_LANES + lane;
      o_partial_sum0 = o_partial_sum0 + 40'(i_q_row0[d_idx]) * 40'(i_k_row[d_idx]);
      if (i_row1_valid)
        o_partial_sum1 = o_partial_sum1 + 40'(i_q_row1[d_idx]) * 40'(i_k_row[d_idx]);
    end
  end
endmodule