class fa_attention_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(fa_attention_reg_adapter)

  function new(string name = "fa_attention_reg_adapter");
    super.new(name);
    supports_byte_enable = 1;
    provides_responses = 1;
  endfunction

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    fa_axil_item item;

    item = fa_axil_item::type_id::create("axil_reg_item");
    item.addr = rw.addr[31:0];
    item.data = rw.data[31:0];
    item.strb = 4'hf;
    item.kind = (rw.kind == UVM_READ) ? FA_AXIL_READ : FA_AXIL_WRITE;
    return item;
  endfunction

  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    fa_axil_item item;

    if (!$cast(item, bus_item)) begin
      `uvm_fatal(get_type_name(), "Unable to cast AXI-Lite transaction into register item")
    end

    rw.addr = item.addr;
    rw.data = item.data;
    rw.kind = (item.kind == FA_AXIL_READ) ? UVM_READ : UVM_WRITE;
    rw.byte_en = item.strb;
    rw.status = (item.resp == 2'b00) ? UVM_IS_OK : UVM_NOT_OK;
  endfunction
endclass