class fa_base_vseq extends uvm_sequence #(uvm_sequence_item);
  `uvm_object_utils(fa_base_vseq)
  `uvm_declare_p_sequencer(fa_virtual_sequencer)

  localparam bit [63:0] Q_BASE = 64'h0000_0000_0010_0000;
  localparam bit [63:0] K_BASE = 64'h0000_0000_0020_0000;
  localparam bit [63:0] V_BASE = 64'h0000_0000_0030_0000;
  localparam bit [63:0] O_BASE = 64'h0000_0000_0040_0000;

  function new(string name = "fa_base_vseq");
    super.new(name);
  endfunction

  protected task write_reg(fa_reg32 reg_h, uvm_reg_data_t value);
    uvm_status_e status;
    reg_h.write(status, value, UVM_FRONTDOOR, p_sequencer.env.regmodel.default_map, this);
    if (status != UVM_IS_OK) begin
      `uvm_fatal(get_type_name(), $sformatf("Register write failed for %s", reg_h.get_name()))
    end
  endtask

  protected task read_reg(fa_reg32 reg_h, output uvm_reg_data_t value);
    uvm_status_e status;
    reg_h.read(status, value, UVM_FRONTDOOR, p_sequencer.env.regmodel.default_map, this);
    if (status != UVM_IS_OK) begin
      `uvm_fatal(get_type_name(), $sformatf("Register read failed for %s", reg_h.get_name()))
    end
  endtask

  protected task write_split64(fa_reg32 reg_lo, fa_reg32 reg_hi, bit [63:0] value);
    write_reg(reg_lo, value[31:0]);
    write_reg(reg_hi, value[63:32]);
  endtask

  protected task wait_clocks(int unsigned cycles);
    repeat (cycles) @(posedge p_sequencer.env.axil_cfg.vif.clk);
  endtask

  protected task program_defaults();
    write_split64(p_sequencer.env.regmodel.q_base_l, p_sequencer.env.regmodel.q_base_h, Q_BASE);
    write_split64(p_sequencer.env.regmodel.k_base_l, p_sequencer.env.regmodel.k_base_h, K_BASE);
    write_split64(p_sequencer.env.regmodel.v_base_l, p_sequencer.env.regmodel.v_base_h, V_BASE);
    write_split64(p_sequencer.env.regmodel.o_base_l, p_sequencer.env.regmodel.o_base_h, O_BASE);
    write_reg(p_sequencer.env.regmodel.stride_bytes, 32'd128);
    write_reg(p_sequencer.env.regmodel.neg_large, 32'hffff_8000);
    write_reg(p_sequencer.env.regmodel.scale, 32'd32);
    write_reg(p_sequencer.env.regmodel.cfg, 32'd0);
  endtask

  protected task check_reset_defaults();
    uvm_reg_data_t value;

    read_reg(p_sequencer.env.regmodel.ctrl, value);
    if (value != 32'd0) `uvm_error(get_type_name(), $sformatf("CTRL reset mismatch 0x%08x", value))
    read_reg(p_sequencer.env.regmodel.cfg, value);
    if (value != 32'd0) `uvm_error(get_type_name(), $sformatf("CFG reset mismatch 0x%08x", value))
    read_reg(p_sequencer.env.regmodel.stride_bytes, value);
    if (value != 32'd128) `uvm_error(get_type_name(), $sformatf("STRIDE reset mismatch 0x%08x", value))
    read_reg(p_sequencer.env.regmodel.neg_large, value);
    if (value != 32'hffff_8000) `uvm_error(get_type_name(), $sformatf("NEG_LARGE reset mismatch 0x%08x", value))
    read_reg(p_sequencer.env.regmodel.scale, value);
    if (value != 32'd32) `uvm_error(get_type_name(), $sformatf("SCALE reset mismatch 0x%08x", value))
  endtask

  protected task start_run();
    write_reg(p_sequencer.env.regmodel.ctrl, 32'h0000_0001);
  endtask

  protected task wait_done();
    uvm_reg_data_t status;

    repeat (20000) begin
      read_reg(p_sequencer.env.regmodel.status, status);
      if (status[2]) begin
        `uvm_fatal(get_type_name(), $sformatf("STATUS error bit set: 0x%08x", status))
      end
      if (status[1]) begin
        return;
      end
      wait_clocks(20);
    end

    `uvm_fatal(get_type_name(), "Timed out waiting for done-sticky")
  endtask

  protected task clear_done_sticky();
    write_reg(p_sequencer.env.regmodel.status, 32'h0000_0002);
  endtask
endclass