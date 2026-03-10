class fa_attention_reg_predictor extends uvm_reg_predictor #(fa_axil_item);
  `uvm_component_utils(fa_attention_reg_predictor)

  function new(string name = "fa_attention_reg_predictor", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass