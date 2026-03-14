module fa_int8_mac_lane (
  input  logic signed [7:0]  i_a,
  input  logic signed [7:0]  i_b,
  input  logic signed [31:0] i_acc_in,
  output logic signed [31:0] o_acc_out
);
  logic signed [15:0] prod;

  always_comb begin
    prod = i_a * i_b;
    o_acc_out = i_acc_in + {{16{prod[15]}}, prod};
  end
endmodule
