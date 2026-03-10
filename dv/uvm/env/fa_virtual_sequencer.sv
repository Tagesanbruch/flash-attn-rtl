typedef class fa_attention_top_env;

class fa_virtual_sequencer extends uvm_sequencer #(uvm_sequence_item);
  `uvm_component_utils(fa_virtual_sequencer)

  fa_axil_sequencer      axil_seqr;
  fa_attention_top_env   env;

  function new(string name = "fa_virtual_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass