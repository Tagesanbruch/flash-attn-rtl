class fa_base_env extends uvm_env;
  `uvm_component_utils(fa_base_env)

  function new(string name = "fa_base_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass