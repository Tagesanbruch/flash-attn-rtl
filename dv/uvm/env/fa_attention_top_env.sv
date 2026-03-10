class fa_attention_top_env extends fa_base_env;
  `uvm_component_utils(fa_attention_top_env)

  fa_axil_agent_cfg          axil_cfg;
  fa_axi_mem_agent_cfg       axi_mem_cfg;
  fa_axil_agent              axil_agent;
  fa_axi_mem_agent           axi_mem_agent;
  fa_attention_reg_block     regmodel;
  fa_attention_reg_adapter   reg_adapter;
  fa_attention_reg_predictor reg_predictor;
  fa_virtual_sequencer       vseqr;
  fa_scoreboard              scoreboard;
  fa_axil_vif_t              axil_vif;
  fa_axi_mem_vif_t           axi_mem_vif;

  function new(string name = "fa_attention_top_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(fa_axil_vif_t)::get(this, "", "axil_vif", axil_vif)) begin
      `uvm_fatal(get_type_name(), "Missing AXI-Lite virtual interface")
    end
    if (!uvm_config_db#(fa_axi_mem_vif_t)::get(this, "", "axi_mem_vif", axi_mem_vif)) begin
      `uvm_fatal(get_type_name(), "Missing AXI memory virtual interface")
    end

    axil_cfg = fa_axil_agent_cfg::type_id::create("axil_cfg");
    axil_cfg.vif = axil_vif;
    axil_cfg.is_active = UVM_ACTIVE;

    axi_mem_cfg = fa_axi_mem_agent_cfg::type_id::create("axi_mem_cfg");
    axi_mem_cfg.vif = axi_mem_vif;
    axi_mem_cfg.is_active = UVM_ACTIVE;

    uvm_config_db#(fa_axil_agent_cfg)::set(this, "axil_agent", "cfg", axil_cfg);
    uvm_config_db#(fa_axi_mem_agent_cfg)::set(this, "axi_mem_agent", "cfg", axi_mem_cfg);

    axil_agent = fa_axil_agent::type_id::create("axil_agent", this);
    axi_mem_agent = fa_axi_mem_agent::type_id::create("axi_mem_agent", this);
    scoreboard = fa_scoreboard::type_id::create("scoreboard", this);
    vseqr = fa_virtual_sequencer::type_id::create("vseqr", this);

    regmodel = fa_attention_reg_block::type_id::create("regmodel");
    regmodel.build();
    regmodel.lock_model();
    regmodel.default_map.set_auto_predict(0);

    reg_adapter = fa_attention_reg_adapter::type_id::create("reg_adapter");
    reg_predictor = fa_attention_reg_predictor::type_id::create("reg_predictor", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    axil_agent.monitor.ap.connect(scoreboard.axil_imp);
    axil_agent.monitor.ap.connect(reg_predictor.bus_in);
    axi_mem_agent.monitor.ap.connect(scoreboard.axi_mem_imp);

    reg_predictor.map = regmodel.default_map;
    reg_predictor.adapter = reg_adapter;
    regmodel.default_map.set_sequencer(axil_agent.sequencer, reg_adapter);

    vseqr.axil_seqr = axil_agent.sequencer;
    vseqr.env = this;
  endfunction
endclass