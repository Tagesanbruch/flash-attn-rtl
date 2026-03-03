// ============================================================================
// fa_tile_buffer.sv
// Ping-pong double-buffered tile SRAM for K or V data.
// Stores one tile of shape [TILE_ROWS x D] in Q8.8 (16-bit).
// Two banks: one being filled by DMA, the other read by compute.
// ============================================================================
module fa_tile_buffer #(
  parameter int TILE_ROWS  = 64,   // rows per tile (Tk)
  parameter int D          = 64,   // head dimension
  parameter int DATA_W     = 16,   // Q8.8
  parameter int BUS_W      = 128   // AXI data width
) (
  input  logic                 clk,
  input  logic                 rst_n,

  // ---- Control ----
  input  logic                 swap,           // pulse: swap active/fill banks
  output logic                 active_bank,    // which bank compute reads from

  // ---- Write port (DMA fill side) ----
  input  logic                 wr_valid,
  output logic                 wr_ready,
  input  logic [BUS_W-1:0]    wr_data,

  // ---- Read port (compute side) ----
  input  logic [$clog2(TILE_ROWS)-1:0] rd_row,
  input  logic [$clog2(D)-1:0]         rd_col,
  output logic signed [DATA_W-1:0]     rd_data
);

  localparam int ELEMS_PER_BEAT = BUS_W / DATA_W;  // 128/16 = 8
  localparam int TOTAL_ELEMS    = TILE_ROWS * D;    // 64*64 = 4096
  localparam int TOTAL_BEATS    = TOTAL_ELEMS / ELEMS_PER_BEAT; // 512
  localparam int ADDR_W         = $clog2(TOTAL_ELEMS);

  // Storage: 2 banks, each TOTAL_ELEMS x DATA_W
  logic signed [DATA_W-1:0] bank0 [TOTAL_ELEMS];
  logic signed [DATA_W-1:0] bank1 [TOTAL_ELEMS];

  logic fill_bank;  // which bank is being filled
  assign active_bank = ~fill_bank;

  // Write pointer
  logic [$clog2(TOTAL_BEATS):0] wr_beat_cnt;
  assign wr_ready = 1'b1;  // always accept when valid

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fill_bank   <= 1'b0;
      wr_beat_cnt <= '0;
    end else begin
      if (swap) begin
        fill_bank   <= ~fill_bank;
        wr_beat_cnt <= '0;
      end

      if (wr_valid && wr_ready) begin
        for (int i = 0; i < ELEMS_PER_BEAT; i++) begin
          automatic int idx = wr_beat_cnt * ELEMS_PER_BEAT + i;
          if (fill_bank == 1'b0)
            bank0[idx] <= $signed(wr_data[i*DATA_W +: DATA_W]);
          else
            bank1[idx] <= $signed(wr_data[i*DATA_W +: DATA_W]);
        end
        wr_beat_cnt <= wr_beat_cnt + 1'b1;
      end
    end
  end

  // Read port (combinational for low latency)
  logic [ADDR_W-1:0] rd_addr;
  assign rd_addr = rd_row * D + rd_col;

  always_comb begin
    if (active_bank == 1'b0)
      rd_data = bank0[rd_addr];
    else
      rd_data = bank1[rd_addr];
  end
endmodule
