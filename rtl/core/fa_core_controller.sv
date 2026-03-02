module fa_core_controller #(
  parameter int MAX_SIM_CYCLES = 128
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        i_start,
  input  logic        i_soft_reset,
  input  logic        i_causal_en,
  input  logic [15:0] i_scale_q8_8,
  output logic        o_busy,
  output logic        o_done,
  output logic        o_error,
  output logic [31:0] o_cycles
);
  logic [31:0] cycle_counter;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_busy <= 1'b0;
      o_done <= 1'b0;
      o_error <= 1'b0;
      cycle_counter <= 32'd0;
    end else begin
      o_done <= 1'b0;
      if (i_soft_reset) begin
        o_busy <= 1'b0;
        o_error <= 1'b0;
        cycle_counter <= 32'd0;
      end else begin
        if (i_start && !o_busy) begin
          o_busy <= 1'b1;
          cycle_counter <= 32'd0;
        end

        if (o_busy) begin
          cycle_counter <= cycle_counter + 1'b1;
          if (cycle_counter == (MAX_SIM_CYCLES - 1)) begin
            o_busy <= 1'b0;
            o_done <= 1'b1;
          end
        end
      end
    end
  end

  assign o_cycles = cycle_counter;

  logic unused_cfg;
  logic [15:0] unused_scale;
  assign unused_cfg = i_causal_en;
  assign unused_scale = i_scale_q8_8;
endmodule
