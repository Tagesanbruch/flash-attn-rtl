module fa_clip_signed #(
  parameter int IN_W = 32,
  parameter int OUT_W = 16
) (
  input  logic signed [IN_W-1:0]  i_x,
  output logic signed [OUT_W-1:0] o_y
);
  localparam logic signed [IN_W-1:0] MAX_V = (1 <<< (OUT_W-1)) - 1;
  localparam logic signed [IN_W-1:0] MIN_V = - (1 <<< (OUT_W-1));

  always_comb begin
    if (i_x > MAX_V) begin
      o_y = MAX_V[OUT_W-1:0];
    end else if (i_x < MIN_V) begin
      o_y = MIN_V[OUT_W-1:0];
    end else begin
      o_y = i_x[OUT_W-1:0];
    end
  end
endmodule
