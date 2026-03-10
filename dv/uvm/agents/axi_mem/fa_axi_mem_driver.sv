class fa_axi_mem_driver extends uvm_component;
  `uvm_component_utils(fa_axi_mem_driver)

  fa_axi_mem_agent_cfg cfg;

  bit                  rd_active;
  bit [31:0]           rd_addr;
  int unsigned         rd_beats_total;
  int unsigned         rd_idx;
  int unsigned         rd_wait;

  bit                  wr_active;
  bit [31:0]           wr_addr;
  int unsigned         wr_beats_total;
  int unsigned         wr_idx;
  bit                  wr_resp_pending;
  int unsigned         wr_resp_wait;

  function new(string name = "fa_axi_mem_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(fa_axi_mem_agent_cfg)::get(this, "", "cfg", cfg)) begin
      `uvm_fatal(get_type_name(), "Missing AXI memory agent configuration")
    end
  endfunction

  function int unsigned next_latency();
    if (cfg.randomize_latency) begin
      return $urandom_range(0, cfg.max_random_latency);
    end
    return cfg.read_latency;
  endfunction

  task reset_outputs();
    cfg.vif.arready = 1'b1;
    cfg.vif.rid     = '0;
    cfg.vif.rdata   = '0;
    cfg.vif.rresp   = 2'b00;
    cfg.vif.rlast   = 1'b0;
    cfg.vif.rvalid  = 1'b0;
    cfg.vif.awready = 1'b1;
    cfg.vif.wready  = 1'b0;
    cfg.vif.bid     = '0;
    cfg.vif.bresp   = 2'b00;
    cfg.vif.bvalid  = 1'b0;

    rd_active       = 1'b0;
    rd_addr         = '0;
    rd_beats_total  = 0;
    rd_idx          = 0;
    rd_wait         = 0;
    wr_active       = 1'b0;
    wr_addr         = '0;
    wr_beats_total  = 0;
    wr_idx          = 0;
    wr_resp_pending = 1'b0;
    wr_resp_wait    = 0;
  endtask

  task run_phase(uvm_phase phase);
    longint unsigned beat_addr;
    int unsigned bytes_per_beat;

    bytes_per_beat = 16;
    reset_outputs();

    forever begin
      @(posedge cfg.vif.clk);
      if (!cfg.vif.rst_n) begin
        reset_outputs();
        continue;
      end

      if (rd_active && cfg.vif.rvalid && cfg.vif.rready) begin
        rd_idx = rd_idx + 1;
        if (rd_idx >= rd_beats_total) begin
          rd_active = 1'b0;
          cfg.vif.rvalid = 1'b0;
          cfg.vif.rlast = 1'b0;
        end else begin
          rd_wait = next_latency();
        end
      end

      if (wr_active && cfg.vif.wvalid && cfg.vif.wready) begin
        beat_addr = longint'(wr_addr) + longint'(wr_idx) * bytes_per_beat;
        cfg.set_word(beat_addr, cfg.vif.wdata);
        wr_idx = wr_idx + 1;
        if (cfg.vif.wlast || (wr_idx >= wr_beats_total)) begin
          wr_active = 1'b0;
          wr_resp_pending = 1'b1;
          wr_resp_wait = cfg.write_resp_latency;
          cfg.vif.wready = 1'b0;
        end
      end

      if (wr_resp_pending && cfg.vif.bvalid && cfg.vif.bready) begin
        wr_resp_pending = 1'b0;
        cfg.vif.bvalid = 1'b0;
      end

      if (!rd_active && (cfg.vif.arvalid && cfg.vif.arready)) begin
        rd_active = 1'b1;
        rd_addr = cfg.vif.araddr;
        rd_beats_total = cfg.vif.arlen + 1;
        rd_idx = 0;
        rd_wait = next_latency();
      end

      if (!wr_active && !wr_resp_pending && (cfg.vif.awvalid && cfg.vif.awready)) begin
        wr_active = 1'b1;
        wr_addr = cfg.vif.awaddr;
        wr_beats_total = cfg.vif.awlen + 1;
        wr_idx = 0;
      end

      cfg.vif.arready = rd_active ? 1'b0 : 1'b1;
      cfg.vif.awready = (wr_active || wr_resp_pending) ? 1'b0 : 1'b1;
      cfg.vif.wready  = wr_active;

      if (rd_active) begin
        if (rd_wait != 0) begin
          rd_wait = rd_wait - 1;
          cfg.vif.rvalid = 1'b0;
          cfg.vif.rlast = 1'b0;
        end else begin
          beat_addr = longint'(rd_addr) + longint'(rd_idx) * bytes_per_beat;
          cfg.vif.rvalid = 1'b1;
          cfg.vif.rdata = cfg.get_word(beat_addr);
          cfg.vif.rresp = 2'b00;
          cfg.vif.rlast = (rd_idx + 1 == rd_beats_total);
        end
      end else begin
        cfg.vif.rvalid = 1'b0;
        cfg.vif.rlast = 1'b0;
      end

      if (wr_resp_pending) begin
        if (wr_resp_wait != 0) begin
          wr_resp_wait = wr_resp_wait - 1;
          cfg.vif.bvalid = 1'b0;
        end else begin
          cfg.vif.bvalid = 1'b1;
          cfg.vif.bresp = 2'b00;
        end
      end else begin
        cfg.vif.bvalid = 1'b0;
      end
    end
  endtask
endclass