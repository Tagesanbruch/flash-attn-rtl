class fa_axil_monitor extends uvm_component;
  `uvm_component_utils(fa_axil_monitor)

  fa_axil_agent_cfg cfg;
  uvm_analysis_port #(fa_axil_item) ap;

  bit [31:0] wr_addr;
  bit [31:0] wr_data;
  bit [3:0]  wr_strb;
  bit        wr_addr_seen;
  bit        wr_data_seen;
  bit [31:0] rd_addr;
  bit        rd_pending;

  function new(string name = "fa_axil_monitor", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(fa_axil_agent_cfg)::get(this, "", "cfg", cfg)) begin
      `uvm_fatal(get_type_name(), "Missing AXI-Lite agent configuration")
    end
  endfunction

  task run_phase(uvm_phase phase);
    fa_axil_item item;

    forever begin
      @(posedge cfg.vif.clk);
      if (!cfg.vif.rst_n) begin
        wr_addr_seen = 1'b0;
        wr_data_seen = 1'b0;
        rd_pending = 1'b0;
        continue;
      end

      if (cfg.vif.awvalid && cfg.vif.awready) begin
        wr_addr = cfg.vif.awaddr;
        wr_addr_seen = 1'b1;
      end

      if (cfg.vif.wvalid && cfg.vif.wready) begin
        wr_data = cfg.vif.wdata;
        wr_strb = cfg.vif.wstrb;
        wr_data_seen = 1'b1;
      end

      if (wr_addr_seen && wr_data_seen && cfg.vif.bvalid && cfg.vif.bready) begin
        item = fa_axil_item::type_id::create("axil_wr_mon_item");
        item.kind = FA_AXIL_WRITE;
        item.addr = wr_addr;
        item.data = wr_data;
        item.strb = wr_strb;
        item.resp = cfg.vif.bresp;
        ap.write(item);
        wr_addr_seen = 1'b0;
        wr_data_seen = 1'b0;
      end

      if (cfg.vif.arvalid && cfg.vif.arready) begin
        rd_addr = cfg.vif.araddr;
        rd_pending = 1'b1;
      end

      if (rd_pending && cfg.vif.rvalid && cfg.vif.rready) begin
        item = fa_axil_item::type_id::create("axil_rd_mon_item");
        item.kind = FA_AXIL_READ;
        item.addr = rd_addr;
        item.data = cfg.vif.rdata;
        item.strb = '0;
        item.resp = cfg.vif.rresp;
        ap.write(item);
        rd_pending = 1'b0;
      end
    end
  endtask
endclass