class fa_axil_driver extends uvm_driver #(fa_axil_item);
  `uvm_component_utils(fa_axil_driver)

  fa_axil_agent_cfg cfg;

  function new(string name = "fa_axil_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(fa_axil_agent_cfg)::get(this, "", "cfg", cfg)) begin
      `uvm_fatal(get_type_name(), "Missing AXI-Lite agent configuration")
    end
  endfunction

  task run_phase(uvm_phase phase);
    fa_axil_item req;

    drive_idle();
    wait (cfg.vif.rst_n === 1'b1);

    forever begin
      seq_item_port.get_next_item(req);
      case (req.kind)
        FA_AXIL_WRITE: drive_write(req);
        FA_AXIL_READ:  drive_read(req);
      endcase
      seq_item_port.item_done();
    end
  endtask

  task drive_idle();
    cfg.vif.awaddr  = '0;
    cfg.vif.awvalid = 1'b0;
    cfg.vif.wdata   = '0;
    cfg.vif.wstrb   = '0;
    cfg.vif.wvalid  = 1'b0;
    cfg.vif.bready  = 1'b0;
    cfg.vif.araddr  = '0;
    cfg.vif.arvalid = 1'b0;
    cfg.vif.rready  = 1'b0;
  endtask

  task drive_write(fa_axil_item item);
    bit aw_done;
    bit w_done;

    aw_done = 1'b0;
    w_done = 1'b0;
    cfg.vif.awaddr  = item.addr;
    cfg.vif.awvalid = 1'b1;
    cfg.vif.wdata   = item.data;
    cfg.vif.wstrb   = item.strb;
    cfg.vif.wvalid  = 1'b1;

    do begin
      @(posedge cfg.vif.clk);
      if (cfg.vif.awvalid && cfg.vif.awready) begin
        cfg.vif.awvalid = 1'b0;
        aw_done = 1'b1;
      end
      if (cfg.vif.wvalid && cfg.vif.wready) begin
        cfg.vif.wvalid = 1'b0;
        w_done = 1'b1;
      end
    end while (!(aw_done && w_done));

    cfg.vif.bready = 1'b1;
    do begin
      @(posedge cfg.vif.clk);
    end while (!(cfg.vif.bvalid === 1'b1));
    item.resp = cfg.vif.bresp;
    cfg.vif.bready = 1'b0;
  endtask

  task drive_read(fa_axil_item item);
    cfg.vif.araddr  = item.addr;
    cfg.vif.arvalid = 1'b1;
    do begin
      @(posedge cfg.vif.clk);
    end while (!(cfg.vif.arvalid && cfg.vif.arready));
    cfg.vif.arvalid = 1'b0;

    cfg.vif.rready = 1'b1;
    do begin
      @(posedge cfg.vif.clk);
    end while (!(cfg.vif.rvalid === 1'b1));
    item.data = cfg.vif.rdata;
    item.resp = cfg.vif.rresp;
    cfg.vif.rready = 1'b0;
  endtask
endclass