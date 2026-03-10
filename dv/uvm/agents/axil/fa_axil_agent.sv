class fa_axil_agent extends uvm_agent;
  `uvm_component_utils(fa_axil_agent)

  fa_axil_agent_cfg cfg;
  fa_axil_sequencer sequencer;
  fa_axil_driver    driver;
  fa_axil_monitor   monitor;

  function new(string name = "fa_axil_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(fa_axil_agent_cfg)::get(this, "", "cfg", cfg)) begin
      `uvm_fatal(get_type_name(), "Missing AXI-Lite agent configuration")
    end

    monitor = fa_axil_monitor::type_id::create("monitor", this);
    uvm_config_db#(fa_axil_agent_cfg)::set(this, "monitor", "cfg", cfg);

    if (cfg.is_active == UVM_ACTIVE) begin
      sequencer = fa_axil_sequencer::type_id::create("sequencer", this);
      driver = fa_axil_driver::type_id::create("driver", this);
      uvm_config_db#(fa_axil_agent_cfg)::set(this, "driver", "cfg", cfg);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg.is_active == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
  endfunction
endclass