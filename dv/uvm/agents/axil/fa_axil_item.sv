class fa_axil_item extends uvm_sequence_item;
  rand fa_axil_kind_e kind;
  rand bit [31:0] addr;
  rand bit [31:0] data;
  rand bit [3:0]  strb;
  bit [1:0]       resp;

  `uvm_object_utils_begin(fa_axil_item)
    `uvm_field_enum(fa_axil_kind_e, kind, UVM_DEFAULT)
    `uvm_field_int(addr, UVM_HEX)
    `uvm_field_int(data, UVM_HEX)
    `uvm_field_int(strb, UVM_HEX)
    `uvm_field_int(resp, UVM_HEX)
  `uvm_object_utils_end

  function new(string name = "fa_axil_item");
    super.new(name);
    strb = 4'hf;
  endfunction
endclass