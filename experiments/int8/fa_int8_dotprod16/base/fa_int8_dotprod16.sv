module fa_int8_dotprod16 (
  input  logic [127:0] i_a_vec,
  input  logic [127:0] i_b_vec,
  output logic signed [31:0] o_dot
);
  logic signed [31:0] sum;
  logic signed [7:0] a_i;
  logic signed [7:0] b_i;

  always_comb begin
    sum = 32'sd0;
    for (int i = 0; i < 16; i++) begin
      a_i = i_a_vec[i*8 +: 8];
      b_i = i_b_vec[i*8 +: 8];
      sum = sum + a_i * b_i;
    end
    o_dot = sum;
  end
endmodule
