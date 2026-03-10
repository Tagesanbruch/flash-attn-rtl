class top_smoke_seq extends fa_base_vseq;
  `uvm_object_utils(top_smoke_seq)

  function new(string name = "top_smoke_seq");
    super.new(name);
  endfunction

  virtual task body();
    uvm_reg_data_t value;

    wait (p_sequencer.env.axil_cfg.vif.rst_n === 1'b1);
    check_reset_defaults();
    program_defaults();
    start_run();
    wait_done();

    read_reg(p_sequencer.env.regmodel.cycles, value);
    if (value == 0) begin
      `uvm_error(get_type_name(), "CYCLES register remained zero after completion")
    end

    read_reg(p_sequencer.env.regmodel.perf_run_count, value);
    read_reg(p_sequencer.env.regmodel.perf_busy_cycles, value);
    read_reg(p_sequencer.env.regmodel.perf_dma_rd_cmd_count, value);
    read_reg(p_sequencer.env.regmodel.perf_dma_rd_beat_count, value);
    read_reg(p_sequencer.env.regmodel.perf_dma_wr_cmd_count, value);
    read_reg(p_sequencer.env.regmodel.perf_dma_wr_beat_count, value);

    clear_done_sticky();
    read_reg(p_sequencer.env.regmodel.status, value);
    if (value[1]) begin
      `uvm_error(get_type_name(), "Done-sticky clear failed")
    end
  endtask
endclass