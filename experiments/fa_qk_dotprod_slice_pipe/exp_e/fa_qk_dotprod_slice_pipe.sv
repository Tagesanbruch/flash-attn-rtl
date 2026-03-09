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

  localparam int GSZ = LANES / 8;

  function automatic logic signed [15:0] lane16(
    input logic [LANES*16-1:0] vec,
    input int                  idx
  );
    lane16 = $signed(vec[idx*16 +: 16]);
  endfunction

  logic signed [39:0] mac0_c [8];
  logic signed [39:0] mac1_c [8];
  logic signed [39:0] mac0_r [8];
  logic signed [39:0] mac1_r [8];
  logic signed [39:0] qtr0_r [4];
  logic signed [39:0] qtr1_r [4];
  logic signed [39:0] half0_r [2];
  logic signed [39:0] half1_r [2];
  logic               v1_r, v2_r, v3_r;
  logic               row1_v1_r, row1_v2_r, row1_v3_r;

  always_comb begin
    for (int g = 0; g < 8; g++) begin
      mac0_c[g] = '0;
      mac1_c[g] = '0;
      for (int lane = 0; lane < GSZ; lane++) begin
        int idx;
        idx = g * GSZ + lane;
        mac0_c[g] = mac0_c[g] + 40'(lane16(i_q0_chunk_q8_8, idx)) * 40'(lane16(i_k_chunk_q8_8, idx));
        if (i_row1_valid)
          mac1_c[g] = mac1_c[g] + 40'(lane16(i_q1_chunk_q8_8, idx)) * 40'(lane16(i_k_chunk_q8_8, idx));
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int g = 0; g < 8; g++) begin
        mac0_r[g] <= '0;
        mac1_r[g] <= '0;
      end
      for (int q = 0; q < 4; q++) begin
        qtr0_r[q] <= '0;
        qtr1_r[q] <= '0;
      end
      for (int h = 0; h < 2; h++) begin
        half0_r[h] <= '0;
        half1_r[h] <= '0;
      end
      v1_r <= 1'b0;
      v2_r <= 1'b0;
      v3_r <= 1'b0;
      row1_v1_r <= 1'b0;
      row1_v2_r <= 1'b0;
      row1_v3_r <= 1'b0;
      o_valid <= 1'b0;
      o_partial_sum0 <= '0;
      o_partial_sum1 <= '0;
    end else begin
      for (int g = 0; g < 8; g++) begin
        mac0_r[g] <= mac0_c[g];
        mac1_r[g] <= mac1_c[g];
      end
      v1_r <= i_valid;
      row1_v1_r <= i_row1_valid;

      for (int q = 0; q < 4; q++) begin
        qtr0_r[q] <= mac0_r[q*2] + mac0_r[q*2 + 1];
        qtr1_r[q] <= mac1_r[q*2] + mac1_r[q*2 + 1];
      end
      v2_r <= v1_r;
      row1_v2_r <= row1_v1_r;

      half0_r[0] <= qtr0_r[0] + qtr0_r[1];
      half0_r[1] <= qtr0_r[2] + qtr0_r[3];
      half1_r[0] <= qtr1_r[0] + qtr1_r[1];
      half1_r[1] <= qtr1_r[2] + qtr1_r[3];
      v3_r <= v2_r;
      row1_v3_r <= row1_v2_r;

      o_valid <= v3_r;
      if (v3_r) begin
        o_partial_sum0 <= half0_r[0] + half0_r[1];
        o_partial_sum1 <= row1_v3_r ? (half1_r[0] + half1_r[1]) : 40'sd0;
      end
    end
  end
endmodule