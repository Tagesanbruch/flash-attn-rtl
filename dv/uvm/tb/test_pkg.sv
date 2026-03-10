package fa_test_pkg;
  import uvm_pkg::*;
  import fa_env_pkg::*;
  `include "uvm_macros.svh"

  `include "seq/fa_base_vseq.sv"
  `include "seq/top_smoke_seq.sv"
  `include "seq/perf_counter_seq.sv"

  `include "tests/fa_base_test.sv"
  `include "tests/fa_top_smoke_test.sv"
  `include "tests/fa_perf_test.sv"
endpackage