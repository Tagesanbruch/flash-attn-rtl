class fa_top_smoke_test extends fa_base_test;
  `uvm_component_utils(fa_top_smoke_test)

  function new(string name = "fa_top_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    top_smoke_seq seq;

    phase.raise_objection(this);
    seq = top_smoke_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass