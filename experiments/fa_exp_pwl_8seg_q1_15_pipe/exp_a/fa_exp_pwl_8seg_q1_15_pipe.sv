module fa_exp_pwl_8seg_q1_15_pipe (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               i_valid,
  input  logic signed [15:0] i_x_q8_8,
  output logic               o_valid,
  output logic        [15:0] o_exp_q1_15
);
  logic               s0_valid;
  logic signed [15:0] s0_x_q8_8;
  logic               s1_valid;
  logic               s1_sat_zero;
  logic [7:0]         s1_frac;
  logic [15:0]        s1_y0;
  logic [15:0]        s1_y1;

  logic signed [15:0] x_clamped;
  logic [15:0]        u_q8_8;
  logic [2:0]         seg_idx;
  logic               sat_zero;
  logic [7:0]         frac;
  logic [15:0]        y0;
  logic [15:0]        y1;

  logic [16:0]        delta;
  logic [8:0]         delta_hi;
  logic [7:0]         delta_lo;
  logic [15:0]        interp_hi;
  logic [15:0]        interp_lo;
  logic [15:0]        interp_q1_15;
  logic [15:0]        exp_q1_15;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s0_valid  <= 1'b0;
      s0_x_q8_8 <= 16'sd0;
    end else begin
      s0_valid  <= i_valid;
      s0_x_q8_8 <= i_x_q8_8;
    end
  end

  always_comb begin
    if (s0_x_q8_8 > 16'sd0) begin
      x_clamped = 16'sd0;
    end else if (s0_x_q8_8 < -16'sd4096) begin
      x_clamped = -16'sd4096;
    end else begin
      x_clamped = s0_x_q8_8;
    end

    u_q8_8 = $unsigned(-x_clamped);
    if (u_q8_8[15:8] >= 8) begin
      seg_idx = 3'd0;
      frac = 8'h00;
      sat_zero = 1'b1;
    end else begin
      seg_idx = u_q8_8[10:8];
      frac = u_q8_8[7:0];
      sat_zero = 1'b0;
    end

    if (sat_zero) begin
      y0 = 16'd0;
      y1 = 16'd0;
    end else begin
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
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid    <= 1'b0;
      s1_sat_zero <= 1'b0;
      s1_frac     <= 8'd0;
      s1_y0       <= 16'd0;
      s1_y1       <= 16'd0;
    end else begin
      s1_valid    <= s0_valid;
      s1_sat_zero <= sat_zero;
      s1_frac     <= frac;
      s1_y0       <= y0;
      s1_y1       <= y1;
    end
  end

  always_comb begin
    delta = s1_y0 - s1_y1;
    delta_hi = delta[16:8];
    delta_lo = delta[7:0];
    interp_hi = delta_hi * s1_frac;
    interp_lo = (delta_lo * s1_frac) >> 8;
    interp_q1_15 = interp_hi + interp_lo;

    if (s1_sat_zero) begin
      exp_q1_15 = 16'd0;
    end else if (s1_y0 > interp_q1_15) begin
      exp_q1_15 = s1_y0 - interp_q1_15;
    end else begin
      exp_q1_15 = 16'd0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_valid      <= 1'b0;
      o_exp_q1_15 <= 16'd0;
    end else begin
      o_valid <= s1_valid;
      if (s1_valid) begin
        o_exp_q1_15 <= exp_q1_15;
      end
    end
  end
endmodule
