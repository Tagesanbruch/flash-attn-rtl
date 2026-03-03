module fa_attention_ip_top #(
  parameter int AXIL_ADDR_W = 32,
  parameter int AXIL_DATA_W = 32,
  parameter int AXI_DATA_W  = 128,
  parameter int AXI_ADDR_W  = 32,
  parameter int AXI_ID_W    = 4
) (
  input  logic                        clk,
  input  logic                        rst_n,

  // ==== AXI4-Lite slave (control) ====
  input  logic [AXIL_ADDR_W-1:0]      s_axil_awaddr,
  input  logic                        s_axil_awvalid,
  output logic                        s_axil_awready,
  input  logic [AXIL_DATA_W-1:0]      s_axil_wdata,
  input  logic [AXIL_DATA_W/8-1:0]    s_axil_wstrb,
  input  logic                        s_axil_wvalid,
  output logic                        s_axil_wready,
  output logic [1:0]                  s_axil_bresp,
  output logic                        s_axil_bvalid,
  input  logic                        s_axil_bready,

  input  logic [AXIL_ADDR_W-1:0]      s_axil_araddr,
  input  logic                        s_axil_arvalid,
  output logic                        s_axil_arready,
  output logic [AXIL_DATA_W-1:0]      s_axil_rdata,
  output logic [1:0]                  s_axil_rresp,
  output logic                        s_axil_rvalid,
  input  logic                        s_axil_rready,

  // ==== AXI4 Master (data DMA) ====
  // -- AR --
  output logic [AXI_ID_W-1:0]        m_axi_arid,
  output logic [AXI_ADDR_W-1:0]      m_axi_araddr,
  output logic [7:0]                  m_axi_arlen,
  output logic [2:0]                  m_axi_arsize,
  output logic [1:0]                  m_axi_arburst,
  output logic                        m_axi_arvalid,
  input  logic                        m_axi_arready,
  // -- R --
  input  logic [AXI_ID_W-1:0]        m_axi_rid,
  input  logic [AXI_DATA_W-1:0]      m_axi_rdata,
  input  logic [1:0]                  m_axi_rresp,
  input  logic                        m_axi_rlast,
  input  logic                        m_axi_rvalid,
  output logic                        m_axi_rready,
  // -- AW --
  output logic [AXI_ID_W-1:0]        m_axi_awid,
  output logic [AXI_ADDR_W-1:0]      m_axi_awaddr,
  output logic [7:0]                  m_axi_awlen,
  output logic [2:0]                  m_axi_awsize,
  output logic [1:0]                  m_axi_awburst,
  output logic                        m_axi_awvalid,
  input  logic                        m_axi_awready,
  // -- W --
  output logic [AXI_DATA_W-1:0]      m_axi_wdata,
  output logic [AXI_DATA_W/8-1:0]    m_axi_wstrb,
  output logic                        m_axi_wlast,
  output logic                        m_axi_wvalid,
  input  logic                        m_axi_wready,
  // -- B --
  input  logic [AXI_ID_W-1:0]        m_axi_bid,
  input  logic [1:0]                  m_axi_bresp,
  input  logic                        m_axi_bvalid,
  output logic                        m_axi_bready
);

  // ---- Internal wires ----
  logic        start_pulse;
  logic        soft_reset;
  logic        irq_en;
  logic        causal_en;
  logic [63:0] q_base, k_base, v_base, o_base;
  logic [31:0] stride_bytes;
  logic [15:0] neg_large_q8_8;
  logic [15:0] scale_q8_8;
  logic        core_busy, core_done, core_error;
  logic [31:0] core_cycles;

  // DMA reader <-> core
  logic        dma_rd_cmd_valid, dma_rd_cmd_ready;
  logic [31:0] dma_rd_cmd_addr;
  logic [15:0] dma_rd_cmd_len;
  logic        dma_rd_out_valid, dma_rd_out_ready;
  logic [AXI_DATA_W-1:0] dma_rd_out_data;
  logic        dma_rd_out_last;
  logic        dma_rd_error;
  logic [31:0] rd_bytes;

  // DMA writer <-> core
  logic        dma_wr_cmd_valid, dma_wr_cmd_ready;
  logic [31:0] dma_wr_cmd_addr;
  logic [15:0] dma_wr_cmd_len;
  logic        dma_wr_in_valid, dma_wr_in_ready;
  logic [AXI_DATA_W-1:0] dma_wr_in_data;
  logic        dma_wr_in_last;
  logic        dma_wr_error;
  logic [31:0] wr_bytes;

  // ==== Register file ====
  fa_axi_lite_regs u_regs (
    .clk(clk), .rst_n(rst_n),
    .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
    .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),
    .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
    .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
    .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp), .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
    .i_busy(core_busy), .i_done(core_done), .i_error(core_error), .i_cycles(core_cycles),
    .o_start_pulse(start_pulse), .o_soft_reset(soft_reset), .o_irq_en(irq_en), .o_causal_en(causal_en),
    .o_q_base(q_base), .o_k_base(k_base), .o_v_base(v_base), .o_o_base(o_base),
    .o_stride_bytes(stride_bytes), .o_neg_large_q8_8(neg_large_q8_8), .o_scale_q8_8(scale_q8_8)
  );

  // ==== DMA Reader ====
  fa_dma_reader #(
    .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W)
  ) u_dma_rd (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(dma_rd_cmd_valid), .cmd_ready(dma_rd_cmd_ready),
    .cmd_addr(dma_rd_cmd_addr), .cmd_len(dma_rd_cmd_len),
    .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
    .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
    .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
    .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
    .out_valid(dma_rd_out_valid), .out_data(dma_rd_out_data),
    .out_last(dma_rd_out_last), .out_ready(dma_rd_out_ready),
    .error(dma_rd_error), .rd_bytes(rd_bytes)
  );

  // ==== DMA Writer ====
  fa_dma_writer #(
    .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W)
  ) u_dma_wr (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(dma_wr_cmd_valid), .cmd_ready(dma_wr_cmd_ready),
    .cmd_addr(dma_wr_cmd_addr), .cmd_len(dma_wr_cmd_len),
    .in_valid(dma_wr_in_valid), .in_ready(dma_wr_in_ready),
    .in_data(dma_wr_in_data), .in_last(dma_wr_in_last),
    .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
    .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
    .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
    .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
    .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
    .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
    .error(dma_wr_error), .wr_bytes(wr_bytes)
  );

  // ==== Attention Core ====
  fa_attention_core u_core (
    .clk(clk), .rst_n(rst_n),
    .i_start(start_pulse), .i_soft_reset(soft_reset),
    .i_causal_en(causal_en), .i_scale_q8_8(scale_q8_8),
    .i_neg_large_q8_8(neg_large_q8_8),
    .o_busy(core_busy), .o_done(core_done), .o_error(core_error), .o_cycles(core_cycles),
    .i_q_base(q_base), .i_k_base(k_base), .i_v_base(v_base), .i_o_base(o_base),
    .i_stride_bytes(stride_bytes),
    .dma_rd_cmd_valid(dma_rd_cmd_valid), .dma_rd_cmd_ready(dma_rd_cmd_ready),
    .dma_rd_cmd_addr(dma_rd_cmd_addr), .dma_rd_cmd_len(dma_rd_cmd_len),
    .dma_rd_data_valid(dma_rd_out_valid), .dma_rd_data_ready(dma_rd_out_ready),
    .dma_rd_data(dma_rd_out_data), .dma_rd_data_last(dma_rd_out_last),
    .dma_wr_cmd_valid(dma_wr_cmd_valid), .dma_wr_cmd_ready(dma_wr_cmd_ready),
    .dma_wr_cmd_addr(dma_wr_cmd_addr), .dma_wr_cmd_len(dma_wr_cmd_len),
    .dma_wr_data_valid(dma_wr_in_valid), .dma_wr_data_ready(dma_wr_in_ready),
    .dma_wr_data(dma_wr_in_data), .dma_wr_data_last(dma_wr_in_last)
  );

  // Error aggregation
  logic unused_irq;
  assign unused_irq = irq_en;
endmodule
