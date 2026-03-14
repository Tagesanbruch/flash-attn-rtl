module fa_fp8_attention_core_tile2_pipeline (
  input  logic               i_clk,
  input  logic               i_rst_n,
  input  logic               i_start,
  input  logic [63:0]        i_q_vec,
  input  logic [63:0]        i_k_tile0,
  input  logic [63:0]        i_v_tile0,
  input  logic [63:0]        i_k_tile1,
  input  logic [63:0]        i_v_tile1,
  input  logic signed [15:0] i_score_scale_q1_14,
  input  logic [1:0]         i_round_mode,
  input  logic               i_saturate_en,
  output logic               o_busy,
  output logic               o_done,
  output logic signed [31:0] o_ctx_sum_q4_11
);
  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_RUN0 = 2'd1,
    ST_RUN1 = 2'd2,
    ST_DONE = 2'd3
  } state_t;

  state_t st_r, st_n;
  logic signed [31:0] ctx_sum_r, ctx_sum_n;

  function automatic signed [15:0] fp8_e4m3_to_q4_11(input logic [7:0] fp8);
    logic sign;
    logic [3:0] exp;
    logic [2:0] frac;
    logic signed [31:0] mag;
    begin
      sign = fp8[7];
      exp = fp8[6:3];
      frac = fp8[2:0];
      if (exp == 4'd0) begin
        mag = $signed({1'b0, frac}) <<< 2;
      end else if (exp == 4'hF) begin
        mag = 32'sd32767;
      end else begin
        mag = $signed({1'b0, 3'd0, 1'b1, frac}) <<< (exp + 1);
        if (mag > 32'sd32767) begin
          mag = 32'sd32767;
        end
      end
      fp8_e4m3_to_q4_11 = sign ? -mag[15:0] : mag[15:0];
    end
  endfunction

  function automatic signed [39:0] round_shift_right_40(
    input signed [39:0] v,
    input int sh,
    input logic [1:0] round_mode
  );
    logic signed [39:0] t;
    begin
      t = v;
      if (sh <= 0) begin
        round_shift_right_40 = v;
      end else begin
        if (round_mode == 2'd1) begin
          if (v >= 0) begin
            t = v + (40'sd1 <<< (sh - 1));
          end else begin
            t = v - (40'sd1 <<< (sh - 1));
          end
        end
        round_shift_right_40 = t >>> sh;
      end
    end
  endfunction

  function automatic signed [31:0] run_one_tile(
    input logic [63:0] q_vec,
    input logic [63:0] k_vec,
    input logic [63:0] v_vec,
    input logic signed [15:0] score_scale,
    input logic [1:0] round_mode,
    input logic saturate_en
  );
    logic signed [39:0] dot_q8_22;
    logic signed [39:0] score_q8_11;
    logic signed [55:0] score_scaled_q9_25;
    logic signed [55:0] score_scaled_q8_11;
    logic signed [31:0] score_final;
    logic signed [31:0] score_q8_3;
    logic signed [15:0] weight_q0_15;
    logic [4:0] neg_shift;
    logic signed [39:0] pv_sum_q4_26;
    begin
      dot_q8_22 = 40'sd0;
      for (int i = 0; i < 8; i++) begin
        dot_q8_22 = dot_q8_22 +
          ($signed(fp8_e4m3_to_q4_11(q_vec[i*8 +: 8])) *
           $signed(fp8_e4m3_to_q4_11(k_vec[i*8 +: 8])));
      end
      score_q8_11 = round_shift_right_40(dot_q8_22, 11, round_mode);

      score_scaled_q9_25 = score_q8_11 * $signed(score_scale);
      score_scaled_q8_11 = score_scaled_q9_25 >>> 14;
      if (saturate_en) begin
        if (score_scaled_q8_11 > 56'sd2147483647) begin
          score_final = 32'sd2147483647;
        end else if (score_scaled_q8_11 < -56'sd2147483648) begin
          score_final = -32'sd2147483648;
        end else begin
          score_final = score_scaled_q8_11[31:0];
        end
      end else begin
        score_final = score_scaled_q8_11[31:0];
      end

      score_q8_3 = score_final >>> 8;
      neg_shift = 5'd0;
      if (score_q8_3 >= 0) begin
        weight_q0_15 = 16'sd32767;
      end else if (score_q8_3 <= -32'sd15) begin
        weight_q0_15 = 16'sd0;
      end else begin
        neg_shift = -score_q8_3;
        weight_q0_15 = 16'sd32767 >>> neg_shift;
      end

      pv_sum_q4_26 = 40'sd0;
      for (int j = 0; j < 8; j++) begin
        pv_sum_q4_26 = pv_sum_q4_26 +
          ($signed(fp8_e4m3_to_q4_11(v_vec[j*8 +: 8])) * $signed(weight_q0_15));
      end

      run_one_tile = pv_sum_q4_26 >>> 15;
    end
  endfunction

  logic signed [31:0] tile0_ctx;
  logic signed [31:0] tile1_ctx;

  always_comb begin
    tile0_ctx = run_one_tile(i_q_vec, i_k_tile0, i_v_tile0, i_score_scale_q1_14, i_round_mode, i_saturate_en);
    tile1_ctx = run_one_tile(i_q_vec, i_k_tile1, i_v_tile1, i_score_scale_q1_14, i_round_mode, i_saturate_en);

    st_n = st_r;
    ctx_sum_n = ctx_sum_r;

    case (st_r)
      ST_IDLE: begin
        ctx_sum_n = 32'sd0;
        if (i_start) begin
          st_n = ST_RUN0;
        end
      end
      ST_RUN0: begin
        ctx_sum_n = tile0_ctx;
        st_n = ST_RUN1;
      end
      ST_RUN1: begin
        ctx_sum_n = ctx_sum_r + tile1_ctx;
        st_n = ST_DONE;
      end
      ST_DONE: begin
        if (!i_start) begin
          st_n = ST_IDLE;
        end
      end
      default: begin
        st_n = ST_IDLE;
      end
    endcase
  end

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      st_r <= ST_IDLE;
      ctx_sum_r <= 32'sd0;
    end else begin
      st_r <= st_n;
      ctx_sum_r <= ctx_sum_n;
    end
  end

  assign o_busy = (st_r == ST_RUN0) || (st_r == ST_RUN1);
  assign o_done = (st_r == ST_DONE);
  assign o_ctx_sum_q4_11 = ctx_sum_r;
endmodule
