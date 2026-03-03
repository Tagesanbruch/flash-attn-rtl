// ============================================================================
// fa_dma_reader.sv
// AXI4 Master read-only DMA: issues burst reads to fetch Q/K/V tiles.
// Produces a simple valid/data stream to downstream tile buffer.
// ============================================================================
module fa_dma_reader #(
  parameter int AXI_ADDR_W  = 32,
  parameter int AXI_DATA_W  = 128,  // 128-bit bus = 8 Q8.8 elements per beat
  parameter int AXI_ID_W    = 4,
  parameter int AXI_LEN_W   = 8
) (
  input  logic                      clk,
  input  logic                      rst_n,

  // ---- Command interface (from scheduler) ----
  input  logic                      cmd_valid,
  output logic                      cmd_ready,
  input  logic [AXI_ADDR_W-1:0]    cmd_addr,
  input  logic [AXI_LEN_W-1:0]     cmd_len,       // ARLEN value (beats-1)

  // ---- AXI4 Master AR channel ----
  output logic [AXI_ID_W-1:0]      m_axi_arid,
  output logic [AXI_ADDR_W-1:0]    m_axi_araddr,
  output logic [AXI_LEN_W-1:0]     m_axi_arlen,
  output logic [2:0]               m_axi_arsize,
  output logic [1:0]               m_axi_arburst,
  output logic                     m_axi_arvalid,
  input  logic                     m_axi_arready,

  // ---- AXI4 Master R channel ----
  input  logic [AXI_ID_W-1:0]      m_axi_rid,
  input  logic [AXI_DATA_W-1:0]    m_axi_rdata,
  input  logic [1:0]               m_axi_rresp,
  input  logic                     m_axi_rlast,
  input  logic                     m_axi_rvalid,
  output logic                     m_axi_rready,

  // ---- Data output stream (to tile buffer) ----
  output logic                     out_valid,
  output logic [AXI_DATA_W-1:0]   out_data,
  output logic                     out_last,      // last beat of this burst
  input  logic                     out_ready,

  // ---- Status ----
  output logic                     error,         // any RRESP error
  output logic [31:0]              rd_bytes       // total bytes read
);

  // AR channel state machine
  typedef enum logic [1:0] {
    AR_IDLE, AR_SEND
  } ar_state_t;
  ar_state_t ar_state;

  logic [AXI_ADDR_W-1:0] ar_addr_r;
  logic [AXI_LEN_W-1:0]  ar_len_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_state  <= AR_IDLE;
      ar_addr_r <= '0;
      ar_len_r  <= '0;
    end else begin
      case (ar_state)
        AR_IDLE: begin
          if (cmd_valid && cmd_ready) begin
            ar_addr_r <= cmd_addr;
            ar_len_r  <= cmd_len;
            ar_state  <= AR_SEND;
          end
        end
        AR_SEND: begin
          if (m_axi_arvalid && m_axi_arready) begin
            ar_state <= AR_IDLE;
          end
        end
        default: ar_state <= AR_IDLE;
      endcase
    end
  end

  assign cmd_ready      = (ar_state == AR_IDLE);
  assign m_axi_arid     = '0;
  assign m_axi_araddr   = ar_addr_r;
  assign m_axi_arlen    = ar_len_r;
  assign m_axi_arsize   = $clog2(AXI_DATA_W / 8);  // e.g. 4 for 16 bytes
  assign m_axi_arburst  = 2'b01;  // INCR
  assign m_axi_arvalid  = (ar_state == AR_SEND);

  // R channel: pass through to output stream
  assign out_valid     = m_axi_rvalid;
  assign out_data      = m_axi_rdata;
  assign out_last      = m_axi_rlast;
  assign m_axi_rready  = out_ready;

  // Error flag: sticky on any non-OKAY response
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      error <= 1'b0;
    else if (m_axi_rvalid && m_axi_rready && (m_axi_rresp != 2'b00))
      error <= 1'b1;
  end

  // Byte counter
  localparam int BYTES_PER_BEAT = AXI_DATA_W / 8;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      rd_bytes <= 32'd0;
    else if (m_axi_rvalid && m_axi_rready)
      rd_bytes <= rd_bytes + BYTES_PER_BEAT;
  end

  // Unused
  logic unused;
  assign unused = ^m_axi_rid;
endmodule
