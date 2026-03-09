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

  localparam int GSZ = LANES / 2;

  function automatic logic signed [15:0] lane16(
    input logic [LANES*16-1:0] vec,
    input int                  idx
  );
    lane16 = $signed(vec[idx*16 +: 16]);
  endfunction

  logic signed [39:0] mac0_c [2];
  logic signed [39:0] mac1_c [2];
  logic signed [39:0] mac0_r [2];
  logic signed [39:0] mac1_r [2];
  logic               v1_r;
  logic               row1_v1_r;

  always_comb begin
    for (int g = 0; g < 2; g++) begin
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
      for (int g = 0; g < 2; g++) begin
        mac0_r[g] <= '0;
        mac1_r[g] <= '0;
      end
      v1_r <= 1'b0;
      row1_v1_r <= 1'b0;
      o_valid <= 1'b0;
      o_partial_sum0 <= '0;
      o_partial_sum1 <= '0;
    end else begin
      for (int g = 0; g < 2; g++) begin
        mac0_r[g] <= mac0_c[g];
        mac1_r[g] <= mac1_c[g];
      end
      v1_r <= i_valid;
      row1_v1_r <= i_row1_valid;

      o_valid <= v1_r;
      if (v1_r) begin
        o_partial_sum0 <= mac0_r[0] + mac0_r[1];
        o_partial_sum1 <= row1_v1_r ? (mac1_r[0] + mac1_r[1]) : 40'sd0;
      end
    end
  end
endmodule