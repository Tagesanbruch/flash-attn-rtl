module fa_fp8_attention_core_tile2_online (
  input  logic               i_clk,
  input  logic               i_rst_n,
  input  logic               i_cfg_start,
  input  logic [1:0]         i_cfg_round_mode,
  input  logic               i_cfg_saturate_en,
  input  logic signed [15:0] i_cfg_score_scale_q1_14,
  input  logic [63:0]        i_q_vec,
  input  logic [63:0]        i_k_tile0,
  input  logic [63:0]        i_v_tile0,
  input  logic [63:0]        i_k_tile1,
  input  logic [63:0]        i_v_tile1,
  output logic               o_status_busy,
  output logic               o_status_done,
  output logic signed [31:0] o_ctx_sum_q4_11,
  output logic [31:0]        o_perf_cycles,
  output logic [31:0]        o_perf_score_steps,
  output logic [31:0]        o_perf_softmax_steps,
  output logic [31:0]        o_perf_pv_steps
);
  typedef enum logic [2:0] {
    ST_IDLE    = 3'd0,
    ST_SCORE0  = 3'd1,
    ST_SCORE1  = 3'd2,
    ST_SOFTMAX = 3'd3,
    ST_CTX0    = 3'd4,
    ST_CTX1    = 3'd5,
    ST_DONE    = 3'd6
  } state_t;

  state_t st_r, st_n;

  logic signed [31:0] score0_r, score0_n;
  logic signed [31:0] score1_r, score1_n;
  logic signed [15:0] weight0_r, weight0_n;
  logic signed [15:0] weight1_r, weight1_n;
  logic signed [31:0] ctx_sum_r, ctx_sum_n;

  logic [31:0] perf_cycles_r, perf_cycles_n;
  logic [31:0] perf_score_steps_r, perf_score_steps_n;
  logic [31:0] perf_softmax_steps_r, perf_softmax_steps_n;
  logic [31:0] perf_pv_steps_r, perf_pv_steps_n;

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

  function automatic signed [31:0] compute_scaled_score(
    input logic [63:0] q_vec,
    input logic [63:0] k_vec,
    input logic [1:0] round_mode,
    input logic saturate_en,
    input logic signed [15:0] scale_q1_14
  );
    logic signed [39:0] dot_q8_22;
    logic signed [39:0] score_q8_11;
    logic signed [55:0] score_scaled_q9_25;
    logic signed [55:0] score_scaled_q8_11;
    logic signed [31:0] score_final;
    begin
      dot_q8_22 = 40'sd0;
      for (int i = 0; i < 8; i++) begin
        dot_q8_22 = dot_q8_22 +
          ($signed(fp8_e4m3_to_q4_11(q_vec[i*8 +: 8])) *
           $signed(fp8_e4m3_to_q4_11(k_vec[i*8 +: 8])));
      end
      score_q8_11 = round_shift_right_40(dot_q8_22, 11, round_mode);
      score_scaled_q9_25 = score_q8_11 * $signed(scale_q1_14);
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

      compute_scaled_score = score_final;
    end
  endfunction

  function automatic signed [15:0] exp2_approx_q0_15(input logic signed [31:0] delta_q8_11);
    logic signed [31:0] delta_q8_3;
    logic [4:0] neg_shift;
    begin
      delta_q8_3 = delta_q8_11 >>> 8;
      neg_shift = 5'd0;
      if (delta_q8_3 >= 0) begin
        exp2_approx_q0_15 = 16'sd32767;
      end else if (delta_q8_3 <= -32'sd15) begin
        exp2_approx_q0_15 = 16'sd0;
      end else begin
        neg_shift = -delta_q8_3;
        exp2_approx_q0_15 = 16'sd32767 >>> neg_shift;
      end
    end
  endfunction

  function automatic signed [31:0] compute_pv_ctx(
    input logic [63:0] v_vec,
    input logic signed [15:0] weight_q0_15
  );
    logic signed [39:0] pv_sum_q4_26;
    begin
      pv_sum_q4_26 = 40'sd0;
      for (int i = 0; i < 8; i++) begin
        pv_sum_q4_26 = pv_sum_q4_26 +
          ($signed(fp8_e4m3_to_q4_11(v_vec[i*8 +: 8])) * $signed(weight_q0_15));
      end
      compute_pv_ctx = pv_sum_q4_26 >>> 15;
    end
  endfunction

  logic signed [31:0] score_max;
  logic signed [15:0] e0_q0_15;
  logic signed [15:0] e1_q0_15;
  logic [16:0] e_sum;
  logic [31:0] w0_q0_30;
  logic [31:0] w1_q0_30;

  always_comb begin
    score_max = (score0_r >= score1_r) ? score0_r : score1_r;
    e0_q0_15 = exp2_approx_q0_15(score0_r - score_max);
    e1_q0_15 = exp2_approx_q0_15(score1_r - score_max);
    e_sum = {1'b0, e0_q0_15} + {1'b0, e1_q0_15};

    w0_q0_30 = 32'd0;
    w1_q0_30 = 32'd0;
    if (e_sum != 0) begin
      w0_q0_30 = ({16'd0, e0_q0_15} <<< 15) / e_sum;
      w1_q0_30 = ({16'd0, e1_q0_15} <<< 15) / e_sum;
    end

    st_n = st_r;
    score0_n = score0_r;
    score1_n = score1_r;
    weight0_n = weight0_r;
    weight1_n = weight1_r;
    ctx_sum_n = ctx_sum_r;

    perf_cycles_n = perf_cycles_r;
    perf_score_steps_n = perf_score_steps_r;
    perf_softmax_steps_n = perf_softmax_steps_r;
    perf_pv_steps_n = perf_pv_steps_r;

    case (st_r)
      ST_IDLE: begin
        if (i_cfg_start) begin
          st_n = ST_SCORE0;
          score0_n = 32'sd0;
          score1_n = 32'sd0;
          weight0_n = 16'sd0;
          weight1_n = 16'sd0;
          ctx_sum_n = 32'sd0;
          perf_cycles_n = 32'd0;
          perf_score_steps_n = 32'd0;
          perf_softmax_steps_n = 32'd0;
          perf_pv_steps_n = 32'd0;
        end
      end
      ST_SCORE0: begin
        st_n = ST_SCORE1;
        score0_n = compute_scaled_score(i_q_vec, i_k_tile0, i_cfg_round_mode, i_cfg_saturate_en, i_cfg_score_scale_q1_14);
        perf_cycles_n = perf_cycles_r + 1;
        perf_score_steps_n = perf_score_steps_r + 1;
      end
      ST_SCORE1: begin
        st_n = ST_SOFTMAX;
        score1_n = compute_scaled_score(i_q_vec, i_k_tile1, i_cfg_round_mode, i_cfg_saturate_en, i_cfg_score_scale_q1_14);
        perf_cycles_n = perf_cycles_r + 1;
        perf_score_steps_n = perf_score_steps_r + 1;
      end
      ST_SOFTMAX: begin
        st_n = ST_CTX0;
        if (e_sum == 0) begin
          weight0_n = 16'sd16384;
          weight1_n = 16'sd16384;
        end else begin
          if (w0_q0_30 > 32'd32767) begin
            weight0_n = 16'sd32767;
          end else begin
            weight0_n = w0_q0_30[15:0];
          end
          if (w1_q0_30 > 32'd32767) begin
            weight1_n = 16'sd32767;
          end else begin
            weight1_n = w1_q0_30[15:0];
          end
        end
        perf_cycles_n = perf_cycles_r + 1;
        perf_softmax_steps_n = perf_softmax_steps_r + 1;
      end
      ST_CTX0: begin
        st_n = ST_CTX1;
        ctx_sum_n = compute_pv_ctx(i_v_tile0, weight0_r);
        perf_cycles_n = perf_cycles_r + 1;
        perf_pv_steps_n = perf_pv_steps_r + 1;
      end
      ST_CTX1: begin
        st_n = ST_DONE;
        ctx_sum_n = ctx_sum_r + compute_pv_ctx(i_v_tile1, weight1_r);
        perf_cycles_n = perf_cycles_r + 1;
        perf_pv_steps_n = perf_pv_steps_r + 1;
      end
      ST_DONE: begin
        if (!i_cfg_start) begin
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
      score0_r <= 32'sd0;
      score1_r <= 32'sd0;
      weight0_r <= 16'sd0;
      weight1_r <= 16'sd0;
      ctx_sum_r <= 32'sd0;
      perf_cycles_r <= 32'd0;
      perf_score_steps_r <= 32'd0;
      perf_softmax_steps_r <= 32'd0;
      perf_pv_steps_r <= 32'd0;
    end else begin
      st_r <= st_n;
      score0_r <= score0_n;
      score1_r <= score1_n;
      weight0_r <= weight0_n;
      weight1_r <= weight1_n;
      ctx_sum_r <= ctx_sum_n;
      perf_cycles_r <= perf_cycles_n;
      perf_score_steps_r <= perf_score_steps_n;
      perf_softmax_steps_r <= perf_softmax_steps_n;
      perf_pv_steps_r <= perf_pv_steps_n;
    end
  end

  assign o_status_busy = (st_r != ST_IDLE) && (st_r != ST_DONE);
  assign o_status_done = (st_r == ST_DONE);
  assign o_ctx_sum_q4_11 = ctx_sum_r;

  assign o_perf_cycles = perf_cycles_r;
  assign o_perf_score_steps = perf_score_steps_r;
  assign o_perf_softmax_steps = perf_softmax_steps_r;
  assign o_perf_pv_steps = perf_pv_steps_r;
endmodule
