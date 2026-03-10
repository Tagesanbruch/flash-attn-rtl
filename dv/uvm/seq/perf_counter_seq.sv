class perf_counter_seq extends top_smoke_seq;
  `uvm_object_utils(perf_counter_seq)

  function new(string name = "perf_counter_seq");
    super.new(name);
  endfunction

  virtual task body();
    uvm_reg_data_t value;

    super.body();

    read_reg(p_sequencer.env.regmodel.perf_comp_launch_count, value);
    read_reg(p_sequencer.env.regmodel.perf_exp_eval_count, value);
    read_reg(p_sequencer.env.regmodel.perf_mul_eval_count, value);
    read_reg(p_sequencer.env.regmodel.perf_recip_req_count, value);
    read_reg(p_sequencer.env.regmodel.perf_recip_rsp_count, value);
    read_reg(p_sequencer.env.regmodel.perf_ms_load_q_cycles, value);
    read_reg(p_sequencer.env.regmodel.perf_ms_init_context_cycles, value);
    read_reg(p_sequencer.env.regmodel.perf_ms_load_k_cycles, value);
    read_reg(p_sequencer.env.regmodel.perf_ms_load_v_cycles, value);
    read_reg(p_sequencer.env.regmodel.perf_ms_compute_cycles, value);
    read_reg(p_sequencer.env.regmodel.perf_ms_normalize_cycles, value);
    read_reg(p_sequencer.env.regmodel.perf_ms_write_o_cycles, value);
    read_reg(p_sequencer.env.regmodel.perf_ms_next_q_cycles, value);
    read_reg(p_sequencer.env.regmodel.perf_cs_dp_run_cycles, value);
    read_reg(p_sequencer.env.regmodel.perf_cs_score_done_cycles, value);
    read_reg(p_sequencer.env.regmodel.perf_cs_softmax_prep_cycles, value);
  endtask
endclass