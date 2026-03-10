class fa_axi_mem_agent extends uvm_agent;
  `uvm_component_utils(fa_axi_mem_agent)

  fa_axi_mem_agent_cfg cfg;
  fa_axi_mem_sequencer sequencer;
  fa_axi_mem_driver    driver;
  fa_axi_mem_monitor   monitor;

  function new(string name = "fa_axi_mem_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(fa_axi_mem_agent_cfg)::get(this, "", "cfg", cfg)) begin
      `uvm_fatal(get_type_name(), "Missing AXI memory agent configuration")
    end

    monitor = fa_axi_mem_monitor::type_id::create("monitor", this);
    uvm_config_db#(fa_axi_mem_agent_cfg)::set(this, "monitor", "cfg", cfg);

    if (cfg.is_active == UVM_ACTIVE) begin
      sequencer = fa_axi_mem_sequencer::type_id::create("sequencer", this);
      driver = fa_axi_mem_driver::type_id::create("driver", this);
      uvm_config_db#(fa_axi_mem_agent_cfg)::set(this, "driver", "cfg", cfg);
    end
  endfunction
endclass