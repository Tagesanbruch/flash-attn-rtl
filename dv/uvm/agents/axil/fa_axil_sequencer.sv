class fa_axil_sequencer extends uvm_sequencer #(fa_axil_item);
  `uvm_component_utils(fa_axil_sequencer)

  function new(string name = "fa_axil_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass