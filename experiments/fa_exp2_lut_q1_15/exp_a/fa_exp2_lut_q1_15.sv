module fa_exp2_lut_q1_15 (
  input  logic signed [15:0] i_x_q8_8,
  output logic        [15:0] o_exp_q1_15
);
  localparam int LUT_BITS = 5;
  localparam int LOG2E_Q8_8 = 16'sd369;

  function automatic [15:0] frac_lut(input logic [LUT_BITS-1:0] idx);
    begin
      case (idx)
        5'd0: frac_lut = 16'd32768;
        5'd1: frac_lut = 16'd32066;
        5'd2: frac_lut = 16'd31379;
        5'd3: frac_lut = 16'd30706;
        5'd4: frac_lut = 16'd30048;
        5'd5: frac_lut = 16'd29405;
        5'd6: frac_lut = 16'd28774;
        5'd7: frac_lut = 16'd28158;
        5'd8: frac_lut = 16'd27554;
        5'd9: frac_lut = 16'd26964;
        5'd10: frac_lut = 16'd26386;
        5'd11: frac_lut = 16'd25821;
        5'd12: frac_lut = 16'd25268;
        5'd13: frac_lut = 16'd24726;
        5'd14: frac_lut = 16'd24196;
        5'd15: frac_lut = 16'd23678;
        5'd16: frac_lut = 16'd23170;
        5'd17: frac_lut = 16'd22674;
        5'd18: frac_lut = 16'd22188;
        5'd19: frac_lut = 16'd21713;
        5'd20: frac_lut = 16'd21247;
        5'd21: frac_lut = 16'd20792;
        5'd22: frac_lut = 16'd20347;
        5'd23: frac_lut = 16'd19911;
        5'd24: frac_lut = 16'd19484;
        5'd25: frac_lut = 16'd19066;
        5'd26: frac_lut = 16'd18658;
        5'd27: frac_lut = 16'd18258;
        5'd28: frac_lut = 16'd17867;
        5'd29: frac_lut = 16'd17484;
        5'd30: frac_lut = 16'd17109;
        default: frac_lut = 16'd16743;
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
    frac_val = frac_lut(frac_part[7:3]);

    if (int_part >= 8'd16) begin
      shifted_val = 16'd0;
    end else begin
      shifted_val = frac_val >> int_part;
    end

    o_exp_q1_15 = shifted_val;
  end
endmodule
