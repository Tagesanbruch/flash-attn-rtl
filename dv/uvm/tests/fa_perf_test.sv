class fa_perf_test extends fa_base_test;
  `uvm_component_utils(fa_perf_test)

  function new(string name = "fa_perf_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    perf_counter_seq seq;

    phase.raise_objection(this);
    seq = perf_counter_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass