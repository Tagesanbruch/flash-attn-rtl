// ============================================================================
// fa_dma_writer.sv
// AXI4 Master write-only DMA: writes O tiles back to memory.
// Accepts a simple valid/data/last stream from compute engine.
// ============================================================================
module fa_dma_writer #(
  parameter int AXI_ADDR_W  = 32,
  parameter int AXI_DATA_W  = 128,
  parameter int AXI_ID_W    = 4,
  parameter int AXI_LEN_W   = 8
) (
  input  logic                      clk,
  input  logic                      rst_n,

  // ---- Command interface (from scheduler) ----
  input  logic                      cmd_valid,
  output logic                      cmd_ready,
  input  logic [AXI_ADDR_W-1:0]    cmd_addr,
  input  logic [AXI_LEN_W-1:0]     cmd_len,

  // ---- Data input stream ----
  input  logic                      in_valid,
  output logic                      in_ready,
  input  logic [AXI_DATA_W-1:0]    in_data,
  input  logic                      in_last,

  // ---- AXI4 Master AW channel ----
  output logic [AXI_ID_W-1:0]      m_axi_awid,
  output logic [AXI_ADDR_W-1:0]    m_axi_awaddr,
  output logic [AXI_LEN_W-1:0]     m_axi_awlen,
  output logic [2:0]               m_axi_awsize,
  output logic [1:0]               m_axi_awburst,
  output logic                     m_axi_awvalid,
  input  logic                     m_axi_awready,

  // ---- AXI4 Master W channel ----
  output logic [AXI_DATA_W-1:0]    m_axi_wdata,
  output logic [AXI_DATA_W/8-1:0]  m_axi_wstrb,
  output logic                     m_axi_wlast,
  output logic                     m_axi_wvalid,
  input  logic                     m_axi_wready,

  // ---- AXI4 Master B channel ----
  input  logic [AXI_ID_W-1:0]      m_axi_bid,
  input  logic [1:0]               m_axi_bresp,
  input  logic                     m_axi_bvalid,
  output logic                     m_axi_bready,

  // ---- Status ----
  output logic                     error,
  output logic [31:0]              wr_bytes
);

  typedef enum logic [2:0] {
    W_IDLE, W_ADDR, W_DATA, W_RESP
  } w_state_t;
  w_state_t w_state;

  logic [AXI_ADDR_W-1:0] aw_addr_r;
  logic [AXI_LEN_W-1:0]  aw_len_r;
  logic [AXI_LEN_W-1:0]  beat_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_state   <= W_IDLE;
      aw_addr_r <= '0;
      aw_len_r  <= '0;
      beat_cnt  <= '0;
    end else begin
      case (w_state)
        W_IDLE: begin
          if (cmd_valid && cmd_ready) begin
            aw_addr_r <= cmd_addr;
            aw_len_r  <= cmd_len;
            beat_cnt  <= '0;
            w_state   <= W_ADDR;
          end
        end
        W_ADDR: begin
          if (m_axi_awvalid && m_axi_awready) begin
            w_state <= W_DATA;
          end
        end
        W_DATA: begin
          if (m_axi_wvalid && m_axi_wready) begin
            beat_cnt <= beat_cnt + 1'b1;
            if (m_axi_wlast)
              w_state <= W_RESP;
          end
        end
        W_RESP: begin
          if (m_axi_bvalid && m_axi_bready)
            w_state <= W_IDLE;
        end
        default: w_state <= W_IDLE;
      endcase
    end
  end

  assign cmd_ready = (w_state == W_IDLE);

  // AW
  assign m_axi_awid    = '0;
  assign m_axi_awaddr  = aw_addr_r;
  assign m_axi_awlen   = aw_len_r;
  assign m_axi_awsize  = 3'($clog2(AXI_DATA_W / 8));
  assign m_axi_awburst = 2'b01;  // INCR
  assign m_axi_awvalid = (w_state == W_ADDR);

  // W
  assign m_axi_wdata  = in_data;
  assign m_axi_wstrb  = {(AXI_DATA_W/8){1'b1}};
  assign m_axi_wlast  = (beat_cnt == aw_len_r);
  assign m_axi_wvalid = (w_state == W_DATA) && in_valid;
  assign in_ready     = (w_state == W_DATA) && m_axi_wready;

  // B
  assign m_axi_bready = (w_state == W_RESP);

  // Error
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      error <= 1'b0;
    else if (m_axi_bvalid && m_axi_bready && (m_axi_bresp != 2'b00))
      error <= 1'b1;
  end

  // Byte counter
  localparam int BYTES_PER_BEAT = AXI_DATA_W / 8;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      wr_bytes <= 32'd0;
    else if (m_axi_wvalid && m_axi_wready)
      wr_bytes <= wr_bytes + BYTES_PER_BEAT;
  end

  logic unused;
  assign unused = ^m_axi_bid;
endmodule
