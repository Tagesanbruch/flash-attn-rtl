module fa_attention_ip_top_tb;
  import uvm_pkg::*;
  import fa_env_pkg::*;
  import fa_test_pkg::*;

  logic clk;

  axil_if #(32, 32) axil_vif(.clk(clk));
  axi_mem_if #(32, 128, 4) axi_mem_vif(.clk(clk));

`ifndef FA_UVM_DISABLE_DUT
  fa_attention_ip_top dut (
    .clk(clk),
    .rst_n(axil_vif.rst_n),
    .s_axil_awaddr(axil_vif.awaddr),
    .s_axil_awvalid(axil_vif.awvalid),
    .s_axil_awready(axil_vif.awready),
    .s_axil_wdata(axil_vif.wdata),
    .s_axil_wstrb(axil_vif.wstrb),
    .s_axil_wvalid(axil_vif.wvalid),
    .s_axil_wready(axil_vif.wready),
    .s_axil_bresp(axil_vif.bresp),
    .s_axil_bvalid(axil_vif.bvalid),
    .s_axil_bready(axil_vif.bready),
    .s_axil_araddr(axil_vif.araddr),
    .s_axil_arvalid(axil_vif.arvalid),
    .s_axil_arready(axil_vif.arready),
    .s_axil_rdata(axil_vif.rdata),
    .s_axil_rresp(axil_vif.rresp),
    .s_axil_rvalid(axil_vif.rvalid),
    .s_axil_rready(axil_vif.rready),
    .m_axi_arid(axi_mem_vif.arid),
    .m_axi_araddr(axi_mem_vif.araddr),
    .m_axi_arlen(axi_mem_vif.arlen),
    .m_axi_arsize(axi_mem_vif.arsize),
    .m_axi_arburst(axi_mem_vif.arburst),
    .m_axi_arvalid(axi_mem_vif.arvalid),
    .m_axi_arready(axi_mem_vif.arready),
    .m_axi_rid(axi_mem_vif.rid),
    .m_axi_rdata(axi_mem_vif.rdata),
    .m_axi_rresp(axi_mem_vif.rresp),
    .m_axi_rlast(axi_mem_vif.rlast),
    .m_axi_rvalid(axi_mem_vif.rvalid),
    .m_axi_rready(axi_mem_vif.rready),
    .m_axi_awid(axi_mem_vif.awid),
    .m_axi_awaddr(axi_mem_vif.awaddr),
    .m_axi_awlen(axi_mem_vif.awlen),
    .m_axi_awsize(axi_mem_vif.awsize),
    .m_axi_awburst(axi_mem_vif.awburst),
    .m_axi_awvalid(axi_mem_vif.awvalid),
    .m_axi_awready(axi_mem_vif.awready),
    .m_axi_wdata(axi_mem_vif.wdata),
    .m_axi_wstrb(axi_mem_vif.wstrb),
    .m_axi_wlast(axi_mem_vif.wlast),
    .m_axi_wvalid(axi_mem_vif.wvalid),
    .m_axi_wready(axi_mem_vif.wready),
    .m_axi_bid(axi_mem_vif.bid),
    .m_axi_bresp(axi_mem_vif.bresp),
    .m_axi_bvalid(axi_mem_vif.bvalid),
    .m_axi_bready(axi_mem_vif.bready)
  );
`endif

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  initial begin
    axil_vif.rst_n = 1'b0;
    axi_mem_vif.rst_n = 1'b0;

    repeat (5) @(posedge clk);
    axil_vif.rst_n = 1'b1;
    axi_mem_vif.rst_n = 1'b1;
  end

  initial begin
    uvm_config_db#(fa_axil_vif_t)::set(null, "*", "axil_vif", axil_vif);
    uvm_config_db#(fa_axi_mem_vif_t)::set(null, "*", "axi_mem_vif", axi_mem_vif);
    run_test();
  end
endmodule