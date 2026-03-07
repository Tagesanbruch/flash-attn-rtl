module fa_exp2_lut_q1_15 (
  input  logic signed [15:0] i_x_q8_8,
  output logic        [15:0] o_exp_q1_15
);
  localparam int LUT_BITS = 4;
  localparam int LOG2E_Q8_8 = 16'sd369;

  function automatic [15:0] frac_lut(input logic [LUT_BITS-1:0] idx);
    begin
      case (idx)
        4'd0: frac_lut = 16'd32768;
        4'd1: frac_lut = 16'd31379;
        4'd2: frac_lut = 16'd30048;
        4'd3: frac_lut = 16'd28774;
        4'd4: frac_lut = 16'd27554;
        4'd5: frac_lut = 16'd26386;
        4'd6: frac_lut = 16'd25268;
        4'd7: frac_lut = 16'd24196;
        4'd8: frac_lut = 16'd23170;
        4'd9: frac_lut = 16'd22188;
        4'd10: frac_lut = 16'd21247;
        4'd11: frac_lut = 16'd20347;
        4'd12: frac_lut = 16'd19484;
        4'd13: frac_lut = 16'd18658;
        4'd14: frac_lut = 16'd17867;
        default: frac_lut = 16'd17109;
      endcase
    end
  endfunction

  logic signed [15:0] x_clamped_q8_8;
  logic        [15:0] mag_q8_8;
  logic        [31:0] z_mul_q16_16;
  logic        [15:0] z_q8_8;
  logic [7:0] int_part;
  logic [7:0] frac_part;
  logic [15:0] frac_val;
  logic [15:0] shifted_val;

  always_comb begin
    if (i_x_q8_8 > 16'sd0) begin
      x_clamped_q8_8 = 16'sd0;
    end else if (i_x_q8_8 < -16'sd4096) begin
      x_clamped_q8_8 = -16'sd4096;
    end else begin
      x_clamped_q8_8 = i_x_q8_8;
    end

    mag_q8_8 = $unsigned(-x_clamped_q8_8);
    z_mul_q16_16 = mag_q8_8 * LOG2E_Q8_8;
    z_q8_8 = (z_mul_q16_16 + 32'd128) >> 8;

    int_part = z_q8_8[15:8];
    frac_part = z_q8_8[7:0];
    frac_val = frac_lut(frac_part[7:4]);

    if (int_part >= 8'd16) begin
      shifted_val = 16'd0;
    end else begin
      shifted_val = frac_val >> int_part;
    end

    o_exp_q1_15 = shifted_val;
  end
endmodule
