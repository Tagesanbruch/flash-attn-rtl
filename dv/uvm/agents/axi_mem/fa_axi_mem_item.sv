class fa_axi_mem_item extends uvm_sequence_item;
  fa_axi_mem_channel_e channel;
  bit [31:0]           addr;
  bit [7:0]            len;
  bit [127:0]          data;
  bit [1:0]            resp;
  bit                  last;

  `uvm_object_utils_begin(fa_axi_mem_item)
    `uvm_field_enum(fa_axi_mem_channel_e, channel, UVM_DEFAULT)
    `uvm_field_int(addr, UVM_HEX)
    `uvm_field_int(len, UVM_DEC)
    `uvm_field_int(data, UVM_HEX)
    `uvm_field_int(resp, UVM_HEX)
    `uvm_field_int(last, UVM_BIN)
  `uvm_object_utils_end

  function new(string name = "fa_axi_mem_item");
    super.new(name);
  endfunction
endclass