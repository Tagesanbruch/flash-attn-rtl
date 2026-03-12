module fa_fp32_to_bf16 (
  input  logic [31:0] i_x_fp32,
  output logic [15:0] o_y_bf16
);
  logic        sign;
  logic [7:0]  exp_fp32;
  logic [22:0] frac_fp32;
  logic [31:0] rounded_fp32;
  logic [6:0]  nan_payload;

  always_comb begin
    sign      = i_x_fp32[31];
    exp_fp32  = i_x_fp32[30:23];
    frac_fp32 = i_x_fp32[22:0];
    rounded_fp32 = i_x_fp32 + 32'h00007FFF + {31'd0, i_x_fp32[16]};
    nan_payload  = frac_fp32[22:16];

    if ((exp_fp32 == 8'hFF) && (frac_fp32 != 23'd0)) begin
      o_y_bf16 = {sign, 8'hFF, (nan_payload[6] || (nan_payload != 7'd0)) ? nan_payload : 7'h40};
    end else begin
      o_y_bf16 = rounded_fp32[31:16];
    end
  end
endmodule
