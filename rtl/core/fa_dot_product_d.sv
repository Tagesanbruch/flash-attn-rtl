// ============================================================================
// fa_dot_product_d.sv
// Compute dot product of two Q8.8 vectors of length D.
// Accepts one element pair per cycle (serial), outputs accumulated result.
// Uses 40-bit accumulator (>32bit as recommended by contest).
// ============================================================================
module fa_dot_product_d #(
  parameter int D     = 64,
  parameter int ACC_W = 40
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     i_start,     // pulse: begin new dot product
  input  logic                     i_valid,     // input element pair valid
  input  logic signed [15:0]       i_a_q8_8,    // Q8.8
  input  logic signed [15:0]       i_b_q8_8,    // Q8.8
  output logic signed [ACC_W-1:0]  o_result,    // Q16.16 (or wider)
  output logic                     o_done       // pulse: result ready
);
  logic signed [31:0] product;     // Q16.16
  logic signed [ACC_W-1:0] acc;
  logic [$clog2(D):0] count;

  always_comb begin
    product = i_a_q8_8 * i_b_q8_8;  // 16x16 -> 32 bit, Q16.16
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc    <= '0;
      count  <= '0;
      o_done <= 1'b0;
    end else begin
      o_done <= 1'b0;

      if (i_start) begin
        acc   <= '0;
        count <= '0;
      end

      if (i_valid) begin
        acc   <= acc + ACC_W'(product);
        count <= count + 1'b1;

        if (count == D - 1) begin
          o_done <= 1'b1;
        end
      end
    end
  end

  assign o_result = acc + (i_valid ? ACC_W'(product) : '0);
  // Note: o_result reflects the running sum including current beat on done cycle.
  // For final value, read o_result when o_done is high.
endmodule
