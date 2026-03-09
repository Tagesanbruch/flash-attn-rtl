module fa_qk_dotprod_slice_pipe #(
  parameter int LANES = 32
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     i_valid,
  input  logic                     i_row1_valid,
  input  logic [LANES*16-1:0]      i_q0_chunk_q8_8,
  input  logic [LANES*16-1:0]      i_q1_chunk_q8_8,
  input  logic [LANES*16-1:0]      i_k_chunk_q8_8,
  output logic                     o_valid,
  output logic signed [39:0]       o_partial_sum0,
  output logic signed [39:0]       o_partial_sum1
);

  localparam int HALF = LANES / 2;

  function automatic logic signed [15:0] lane16(
    input logic [LANES*16-1:0] vec,
    input int                  idx
  );
    lane16 = $signed(vec[idx*16 +: 16]);
  endfunction

  logic signed [39:0] sum0_lo_c, sum0_hi_c;
  logic signed [39:0] sum1_lo_c, sum1_hi_c;
  logic signed [39:0] sum0_lo_r, sum0_hi_r;
  logic signed [39:0] sum1_lo_r, sum1_hi_r;
  logic               valid_r;
  logic               row1_valid_r;

  always_comb begin
    sum0_lo_c = '0;
    sum0_hi_c = '0;
    sum1_lo_c = '0;
    sum1_hi_c = '0;
    for (int lane = 0; lane < HALF; lane++) begin
      sum0_lo_c = sum0_lo_c + 40'(lane16(i_q0_chunk_q8_8, lane)) * 40'(lane16(i_k_chunk_q8_8, lane));
      if (i_row1_valid)
        sum1_lo_c = sum1_lo_c + 40'(lane16(i_q1_chunk_q8_8, lane)) * 40'(lane16(i_k_chunk_q8_8, lane));
    end
    for (int lane = HALF; lane < LANES; lane++) begin
      sum0_hi_c = sum0_hi_c + 40'(lane16(i_q0_chunk_q8_8, lane)) * 40'(lane16(i_k_chunk_q8_8, lane));
      if (i_row1_valid)
        sum1_hi_c = sum1_hi_c + 40'(lane16(i_q1_chunk_q8_8, lane)) * 40'(lane16(i_k_chunk_q8_8, lane));
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sum0_lo_r <= '0;
      sum0_hi_r <= '0;
      sum1_lo_r <= '0;
      sum1_hi_r <= '0;
      valid_r <= 1'b0;
      row1_valid_r <= 1'b0;
      o_valid <= 1'b0;
      o_partial_sum0 <= '0;
      o_partial_sum1 <= '0;
    end else begin
      sum0_lo_r <= sum0_lo_c;
      sum0_hi_r <= sum0_hi_c;
      sum1_lo_r <= sum1_lo_c;
      sum1_hi_r <= sum1_hi_c;
      valid_r <= i_valid;
      row1_valid_r <= i_row1_valid;

      o_valid <= valid_r;
      if (valid_r) begin
        o_partial_sum0 <= sum0_lo_r + sum0_hi_r;
        o_partial_sum1 <= row1_valid_r ? (sum1_lo_r + sum1_hi_r) : 40'sd0;
      end
    end
  end
endmodule