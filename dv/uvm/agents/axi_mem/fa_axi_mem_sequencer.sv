class fa_axi_mem_sequencer extends uvm_sequencer #(fa_axi_mem_item);
  `uvm_component_utils(fa_axi_mem_sequencer)

  function new(string name = "fa_axi_mem_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass