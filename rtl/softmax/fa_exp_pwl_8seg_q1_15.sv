module fa_exp_pwl_8seg_q1_15 (
  input  logic signed [15:0] i_x_q8_8,
  output logic        [15:0] o_exp_q1_15
);
  logic signed [15:0] x_clamped;
  logic [15:0] u_q8_8;
  logic [2:0] seg_idx;
  logic [7:0] frac;
  logic [15:0] y0;
  logic [15:0] y1;
  logic [16:0] delta;
  logic [15:0] interp_q1_15;
  logic [8:0] delta_hi;
  logic [7:0] delta_lo;
  logic [15:0] interp_hi;
  logic [15:0] interp_lo;

  always_comb begin
    if (i_x_q8_8 > 16'sd0) begin
      x_clamped = 16'sd0;
    end else if (i_x_q8_8 < -16'sd2048) begin
      x_clamped = -16'sd2048;
    end else begin
      x_clamped = i_x_q8_8;
    end

    u_q8_8 = $unsigned(-x_clamped);
    if (u_q8_8[15:8] >= 8) begin
      seg_idx = 3'd7;
      frac = 8'hFF;
    end else begin
      seg_idx = u_q8_8[10:8];
      frac = u_q8_8[7:0];
    end

    unique case (seg_idx)
      3'd0: begin y0 = 16'd32767; y1 = 16'd12055; end
      3'd1: begin y0 = 16'd12055; y1 = 16'd4431;  end
      3'd2: begin y0 = 16'd4431;  y1 = 16'd1631;  end
      3'd3: begin y0 = 16'd1631;  y1 = 16'd600;   end
      3'd4: begin y0 = 16'd600;   y1 = 16'd221;   end
      3'd5: begin y0 = 16'd221;   y1 = 16'd81;    end
      3'd6: begin y0 = 16'd81;    y1 = 16'd30;    end
      default: begin y0 = 16'd30; y1 = 16'd11;    end
    endcase

    delta = y0 - y1;
    delta_hi = delta[16:8];
    delta_lo = delta[7:0];
    interp_hi = delta_hi * frac;
    interp_lo = (delta_lo * frac) >> 8;
    interp_q1_15 = interp_hi + interp_lo;
    if (y0 > interp_q1_15) begin
      o_exp_q1_15 = y0 - interp_q1_15;
    end else begin
      o_exp_q1_15 = 16'd0;
    end
  end
endmodule
