module fa_attention_ip_top #(
  parameter int AXIL_ADDR_W = 32,
  parameter int AXIL_DATA_W = 32
) (
  input  logic                        clk,
  input  logic                        rst_n,

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
  input  logic                        s_axil_rready
);
  logic        start_pulse;
  logic        soft_reset;
  logic        irq_en;
  logic        causal_en;
  logic [63:0] q_base;
  logic [63:0] k_base;
  logic [63:0] v_base;
  logic [63:0] o_base;
  logic [31:0] stride_bytes;
  logic [15:0] neg_large_q8_8;
  logic [15:0] scale_q8_8;

  logic        core_busy;
  logic        core_done;
  logic        core_error;
  logic [31:0] core_cycles;

  fa_axi_lite_regs u_regs (
    .clk(clk),
    .rst_n(rst_n),
    .s_axil_awaddr(s_axil_awaddr),
    .s_axil_awvalid(s_axil_awvalid),
    .s_axil_awready(s_axil_awready),
    .s_axil_wdata(s_axil_wdata),
    .s_axil_wstrb(s_axil_wstrb),
    .s_axil_wvalid(s_axil_wvalid),
    .s_axil_wready(s_axil_wready),
    .s_axil_bresp(s_axil_bresp),
    .s_axil_bvalid(s_axil_bvalid),
    .s_axil_bready(s_axil_bready),
    .s_axil_araddr(s_axil_araddr),
    .s_axil_arvalid(s_axil_arvalid),
    .s_axil_arready(s_axil_arready),
    .s_axil_rdata(s_axil_rdata),
    .s_axil_rresp(s_axil_rresp),
    .s_axil_rvalid(s_axil_rvalid),
    .s_axil_rready(s_axil_rready),
    .i_busy(core_busy),
    .i_done(core_done),
    .i_error(core_error),
    .i_cycles(core_cycles),
    .o_start_pulse(start_pulse),
    .o_soft_reset(soft_reset),
    .o_irq_en(irq_en),
    .o_causal_en(causal_en),
    .o_q_base(q_base),
    .o_k_base(k_base),
    .o_v_base(v_base),
    .o_o_base(o_base),
    .o_stride_bytes(stride_bytes),
    .o_neg_large_q8_8(neg_large_q8_8),
    .o_scale_q8_8(scale_q8_8)
  );

  fa_core_controller u_core (
    .clk(clk),
    .rst_n(rst_n),
    .i_start(start_pulse),
    .i_soft_reset(soft_reset),
    .i_causal_en(causal_en),
    .i_scale_q8_8(scale_q8_8),
    .o_busy(core_busy),
    .o_done(core_done),
    .o_error(core_error),
    .o_cycles(core_cycles)
  );

  logic [63:0] unused_addr_mix;
  logic [31:0] unused_stride;
  logic [15:0] unused_neg;
  logic unused_irq;
  assign unused_addr_mix = q_base ^ k_base ^ v_base ^ o_base;
  assign unused_stride = stride_bytes;
  assign unused_neg = neg_large_q8_8;
  assign unused_irq = irq_en;
endmodule
