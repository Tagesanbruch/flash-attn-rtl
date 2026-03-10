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

  localparam int N1 = LANES / 2;
  localparam int N2 = N1 / 2;
  localparam int N3 = N2 / 2;
  localparam int N4 = N3 / 2;

  function automatic logic signed [15:0] lane16(
    input logic [LANES*16-1:0] vec,
    input int                  idx
  );
    lane16 = $signed(vec[idx*16 +: 16]);
  endfunction

  logic [LANES*16-1:0]         q0_in_r;
  logic [LANES*16-1:0]         q1_in_r;
  logic [LANES*16-1:0]         k_in_r;
  logic signed [31:0]          mult0_r [LANES];
  logic signed [31:0]          mult1_r [LANES];
  logic signed [32:0]          add1_0_r [N1];
  logic signed [32:0]          add1_1_r [N1];
  logic signed [33:0]          add2_0_r [N2];
  logic signed [33:0]          add2_1_r [N2];
  logic signed [34:0]          add3_0_r [N3];
  logic signed [34:0]          add3_1_r [N3];
  logic signed [35:0]          add4_0_r [N4];
  logic signed [35:0]          add4_1_r [N4];
  logic signed [36:0]          final0_r;
  logic signed [36:0]          final1_r;
  logic                        v0_r, v1_r, v2_r, v3_r, v4_r, v5_r, v6_r;
  logic                        row1_v0_r, row1_v1_r, row1_v2_r, row1_v3_r, row1_v4_r, row1_v5_r, row1_v6_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q0_in_r <= '0;
      q1_in_r <= '0;
      k_in_r <= '0;
      for (int i = 0; i < LANES; i++) begin
        mult0_r[i] <= '0;
        mult1_r[i] <= '0;
      end
      for (int i = 0; i < N1; i++) begin
        add1_0_r[i] <= '0;
        add1_1_r[i] <= '0;
      end
      for (int i = 0; i < N2; i++) begin
        add2_0_r[i] <= '0;
        add2_1_r[i] <= '0;
      end
      for (int i = 0; i < N3; i++) begin
        add3_0_r[i] <= '0;
        add3_1_r[i] <= '0;
      end
      for (int i = 0; i < N4; i++) begin
        add4_0_r[i] <= '0;
        add4_1_r[i] <= '0;
      end
      final0_r <= '0;
      final1_r <= '0;
      v0_r <= 1'b0;
      v1_r <= 1'b0;
      v2_r <= 1'b0;
      v3_r <= 1'b0;
      v4_r <= 1'b0;
      v5_r <= 1'b0;
      v6_r <= 1'b0;
      row1_v0_r <= 1'b0;
      row1_v1_r <= 1'b0;
      row1_v2_r <= 1'b0;
      row1_v3_r <= 1'b0;
      row1_v4_r <= 1'b0;
      row1_v5_r <= 1'b0;
      row1_v6_r <= 1'b0;
      o_valid <= 1'b0;
      o_partial_sum0 <= '0;
      o_partial_sum1 <= '0;
    end else begin
      q0_in_r <= i_q0_chunk_q8_8;
      q1_in_r <= i_q1_chunk_q8_8;
      k_in_r <= i_k_chunk_q8_8;
      v0_r <= i_valid;
      row1_v0_r <= i_row1_valid;

      for (int i = 0; i < LANES; i++) begin
        mult0_r[i] <= lane16(q0_in_r, i) * lane16(k_in_r, i);
        if (row1_v0_r)
          mult1_r[i] <= lane16(q1_in_r, i) * lane16(k_in_r, i);
        else
          mult1_r[i] <= '0;
      end
      v1_r <= v0_r;
      row1_v1_r <= row1_v0_r;

      for (int i = 0; i < N1; i++) begin
        add1_0_r[i] <= {mult0_r[i*2][31], mult0_r[i*2]} + {mult0_r[i*2 + 1][31], mult0_r[i*2 + 1]};
        add1_1_r[i] <= {mult1_r[i*2][31], mult1_r[i*2]} + {mult1_r[i*2 + 1][31], mult1_r[i*2 + 1]};
      end
      v2_r <= v1_r;
      row1_v2_r <= row1_v1_r;

      for (int i = 0; i < N2; i++) begin
        add2_0_r[i] <= {add1_0_r[i*2][32], add1_0_r[i*2]} + {add1_0_r[i*2 + 1][32], add1_0_r[i*2 + 1]};
        add2_1_r[i] <= {add1_1_r[i*2][32], add1_1_r[i*2]} + {add1_1_r[i*2 + 1][32], add1_1_r[i*2 + 1]};
      end
      v3_r <= v2_r;
      row1_v3_r <= row1_v2_r;

      for (int i = 0; i < N3; i++) begin
        add3_0_r[i] <= {add2_0_r[i*2][33], add2_0_r[i*2]} + {add2_0_r[i*2 + 1][33], add2_0_r[i*2 + 1]};
        add3_1_r[i] <= {add2_1_r[i*2][33], add2_1_r[i*2]} + {add2_1_r[i*2 + 1][33], add2_1_r[i*2 + 1]};
      end
      v4_r <= v3_r;
      row1_v4_r <= row1_v3_r;

      for (int i = 0; i < N4; i++) begin
        add4_0_r[i] <= {add3_0_r[i*2][34], add3_0_r[i*2]} + {add3_0_r[i*2 + 1][34], add3_0_r[i*2 + 1]};
        add4_1_r[i] <= {add3_1_r[i*2][34], add3_1_r[i*2]} + {add3_1_r[i*2 + 1][34], add3_1_r[i*2 + 1]};
      end
      v5_r <= v4_r;
      row1_v5_r <= row1_v4_r;

      final0_r <= {add4_0_r[0][35], add4_0_r[0]} + {add4_0_r[1][35], add4_0_r[1]};
      final1_r <= {add4_1_r[0][35], add4_1_r[0]} + {add4_1_r[1][35], add4_1_r[1]};
      v6_r <= v5_r;
      row1_v6_r <= row1_v5_r;

      o_valid <= v6_r;
      if (v6_r) begin
        o_partial_sum0 <= {{3{final0_r[36]}}, final0_r};
        o_partial_sum1 <= row1_v6_r ? {{3{final1_r[36]}}, final1_r} : 40'sd0;
      end
    end
  end
endmodule