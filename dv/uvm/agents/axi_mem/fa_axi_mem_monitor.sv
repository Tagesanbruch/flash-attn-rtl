class fa_axi_mem_monitor extends uvm_component;
  `uvm_component_utils(fa_axi_mem_monitor)

  fa_axi_mem_agent_cfg cfg;
  uvm_analysis_port #(fa_axi_mem_item) ap;

  function new(string name = "fa_axi_mem_monitor", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(fa_axi_mem_agent_cfg)::get(this, "", "cfg", cfg)) begin
      `uvm_fatal(get_type_name(), "Missing AXI memory agent configuration")
    end
  endfunction

  task run_phase(uvm_phase phase);
    fa_axi_mem_item item;

    forever begin
      @(posedge cfg.vif.clk);
      if (!cfg.vif.rst_n) begin
        continue;
      end

      if (cfg.vif.arvalid && cfg.vif.arready) begin
        item = fa_axi_mem_item::type_id::create("mem_ar_item");
        item.channel = FA_AXI_MEM_READ_CMD;
        item.addr = cfg.vif.araddr;
        item.len = cfg.vif.arlen;
        ap.write(item);
      end

      if (cfg.vif.rvalid && cfg.vif.rready) begin
        item = fa_axi_mem_item::type_id::create("mem_r_item");
        item.channel = FA_AXI_MEM_READ_BEAT;
        item.data = cfg.vif.rdata;
        item.resp = cfg.vif.rresp;
        item.last = cfg.vif.rlast;
        ap.write(item);
      end

      if (cfg.vif.awvalid && cfg.vif.awready) begin
        item = fa_axi_mem_item::type_id::create("mem_aw_item");
        item.channel = FA_AXI_MEM_WRITE_CMD;
        item.addr = cfg.vif.awaddr;
        item.len = cfg.vif.awlen;
        ap.write(item);
      end

      if (cfg.vif.wvalid && cfg.vif.wready) begin
        item = fa_axi_mem_item::type_id::create("mem_w_item");
        item.channel = FA_AXI_MEM_WRITE_BEAT;
        item.data = cfg.vif.wdata;
        item.last = cfg.vif.wlast;
        ap.write(item);
      end

      if (cfg.vif.bvalid && cfg.vif.bready) begin
        item = fa_axi_mem_item::type_id::create("mem_b_item");
        item.channel = FA_AXI_MEM_WRITE_RESP;
        item.resp = cfg.vif.bresp;
        ap.write(item);
      end
    end
  endtask
endclass