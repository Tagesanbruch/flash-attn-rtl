class fa_base_test extends uvm_test;
  `uvm_component_utils(fa_base_test)

  fa_attention_top_env env;

  function new(string name = "fa_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = fa_attention_top_env::type_id::create("env", this);
  endfunction
endclass