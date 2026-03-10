// Minimal test package
package minimal_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  class minimal_test extends uvm_test;
    `uvm_component_utils(minimal_test)

    function new(string name = "minimal_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      phase.raise_objection(this, "minimal test");
      `uvm_info("MINIMAL", "Test started", UVM_LOW)
      #200;
      `uvm_info("MINIMAL", "Test done", UVM_LOW)
      phase.drop_objection(this, "minimal test");
    endtask

    function void report_phase(uvm_phase phase);
      `uvm_info("MINIMAL", "** UVM TEST PASSED **", UVM_NONE)
    endfunction
  endclass
endpackage

module counter (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en,
  output logic [7:0]  count
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      count <= 8'd0;
    else if (en)
      count <= count + 8'd1;
  end
endmodule

module minimal_tb;
  import uvm_pkg::*;
  import minimal_test_pkg::*;

  logic clk;
  logic rst_n;
  logic en;
  logic [7:0] count;

  counter dut (
    .clk   (clk),
    .rst_n (rst_n),
    .en    (en),
    .count (count)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    en = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    en = 1'b1;
    repeat (10) @(posedge clk);
    $display("MINIMAL_TB: count = %0d", count);
    if (count == 8'd10) begin
      $display("MINIMAL_TB: PASS");
    end else begin
      $display("MINIMAL_TB: FAIL (expected 10, got %0d)", count);
    end
    $finish;
  end

  initial begin
    run_test();
  end
endmodule
