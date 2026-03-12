module fa_bf16_to_fp32 (
  input  logic [15:0] i_x_bf16,
  output logic [31:0] o_y_fp32
);
  always_comb begin
    o_y_fp32 = {i_x_bf16, 16'h0000};
  end
endmodule
