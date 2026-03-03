// ============================================================================
// fa_row_context_rf.sv
// Per-row register file for online softmax state: m, l, acc[D].
// Supports multi-tile accumulation: state persists across K/V tiles.
// ============================================================================
module fa_row_context_rf #(
  parameter int NUM_ROWS = 32,     // Tq: rows of Q tile
  parameter int D        = 64,
  parameter int M_W      = 16,     // width of m (Q8.8)
  parameter int L_W      = 32,     // width of l (Q16.16)
  parameter int ACC_W    = 32      // width of each acc element (Q16.16)
) (
  input  logic                      clk,
  input  logic                      rst_n,

  // ---- Init: reset row state (called at start of Q tile) ----
  input  logic                      init,         // pulse: init all rows
  input  logic signed [M_W-1:0]     init_m,       // typically NEG_LARGE

  // ---- Read row state ----
  input  logic [$clog2(NUM_ROWS)-1:0] rd_row,
  output logic signed [M_W-1:0]      rd_m,
  output logic [L_W-1:0]             rd_l,
  output logic signed [ACC_W-1:0]    rd_acc [D],

  // ---- Write row state ----
  input  logic                        wr_en,
  input  logic [$clog2(NUM_ROWS)-1:0] wr_row,
  input  logic signed [M_W-1:0]       wr_m,
  input  logic [L_W-1:0]              wr_l,
  input  logic signed [ACC_W-1:0]     wr_acc [D]
);

  logic signed [M_W-1:0]   m_rf   [NUM_ROWS];
  logic [L_W-1:0]          l_rf   [NUM_ROWS];
  logic signed [ACC_W-1:0] acc_rf [NUM_ROWS][D];

  // Read
  assign rd_m = m_rf[rd_row];
  assign rd_l = l_rf[rd_row];
  generate
    for (genvar k = 0; k < D; k++) begin : gen_rd_acc
      assign rd_acc[k] = acc_rf[rd_row][k];
    end
  endgenerate

  // Write / Init
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int r = 0; r < NUM_ROWS; r++) begin
        m_rf[r] <= '0;
        l_rf[r] <= '0;
        for (int k = 0; k < D; k++)
          acc_rf[r][k] <= '0;
      end
    end else if (init) begin
      for (int r = 0; r < NUM_ROWS; r++) begin
        m_rf[r] <= init_m;
        l_rf[r] <= '0;
        for (int k = 0; k < D; k++)
          acc_rf[r][k] <= '0;
      end
    end else if (wr_en) begin
      m_rf[wr_row]   <= wr_m;
      l_rf[wr_row]   <= wr_l;
      for (int k = 0; k < D; k++)
        acc_rf[wr_row][k] <= wr_acc[k];
    end
  end
endmodule
