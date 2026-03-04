// ============================================================================
// fa_attention_core.sv
// FlashAttention core: tile-loop controller + compute engine + row context.
// Orchestrates the outer Q-loop and inner K/V-loop, interfacing with
// DMA reader/writer and tile buffers managed by the top level.
// ============================================================================
module fa_attention_core #(
  parameter int SEQ_LEN   = 256,
  parameter int D         = 64,
  parameter int TQ        = 32,   // Q tile rows
  parameter int TK        = 64,   // K/V tile rows
  parameter int BUS_W     = 128
) (
  input  logic                     clk,
  input  logic                     rst_n,

  // ---- Control ----
  input  logic                     i_start,
  input  logic                     i_soft_reset,
  input  logic                     i_causal_en,
  input  logic signed [15:0]       i_scale_q8_8,
  input  logic signed [15:0]       i_neg_large_q8_8,
  output logic                     o_busy,
  output logic                     o_done,
  output logic                     o_error,
  output logic [31:0]              o_cycles,

  // ---- Address config ----
  input  logic [63:0]              i_q_base,
  input  logic [63:0]              i_k_base,
  input  logic [63:0]              i_v_base,
  input  logic [63:0]              i_o_base,
  input  logic [31:0]              i_stride_bytes,

  // ---- DMA reader command ----
  output logic                     dma_rd_cmd_valid,
  input  logic                     dma_rd_cmd_ready,
  output logic [31:0]              dma_rd_cmd_addr,
  output logic [15:0]              dma_rd_cmd_len,

  // ---- DMA reader data (from external reader) ----
  input  logic                     dma_rd_data_valid,
  output logic                     dma_rd_data_ready,
  input  logic [BUS_W-1:0]         dma_rd_data,
  input  logic                     dma_rd_data_last,

  // ---- DMA writer command ----
  output logic                     dma_wr_cmd_valid,
  input  logic                     dma_wr_cmd_ready,
  output logic [31:0]              dma_wr_cmd_addr,
  output logic [15:0]              dma_wr_cmd_len,

  // ---- DMA writer data ----
  output logic                     dma_wr_data_valid,
  input  logic                     dma_wr_data_ready,
  output logic [BUS_W-1:0]         dma_wr_data,
  output logic                     dma_wr_data_last
);

  // ---- Parameters ----
  localparam int NUM_Q_TILES = SEQ_LEN / TQ;  // 8
  localparam int NUM_K_TILES = SEQ_LEN / TK;  // 4
  localparam int ELEMS_PER_BEAT = BUS_W / 16; // 8
  localparam int BEATS_PER_ROW  = D / ELEMS_PER_BEAT; // 8
  localparam int BEATS_PER_TILE_KV = TK * BEATS_PER_ROW; // 512
  localparam int BEATS_PER_TILE_Q  = TQ * BEATS_PER_ROW; // 256
  localparam int DP_LANES = 32;
  localparam int DP_CHUNKS = D / DP_LANES;
  localparam int ROW_PAR = 2;
  localparam int NORM_LANES = 8;

  // ---- Master state machine ----
  typedef enum logic [3:0] {
    S_IDLE,
    S_LOAD_Q,         // DMA fetch Q tile
    S_INIT_CONTEXT,   // Init row context for new Q tile
    S_LOAD_K,         // DMA fetch K tile
    S_LOAD_V,         // DMA fetch V tile
    S_COMPUTE,        // Tile compute (QK^T + online softmax + PV)
    S_NEXT_K,         // Advance K/V tile index
    S_NORMALIZE,      // Final row normalization (acc/l)
    S_WRITE_O,        // DMA write O tile
    S_NEXT_Q,         // Advance Q tile index
    S_DONE
  } master_state_t;
  master_state_t ms;

  logic [$clog2(NUM_Q_TILES):0] q_tile_idx;
  logic [$clog2(NUM_K_TILES):0] k_tile_idx;
  logic [31:0] cycle_counter;

  // ---- Q local buffer ----
  logic signed [15:0] q_buf [TQ][D];
  logic [$clog2(TQ*D/ELEMS_PER_BEAT):0] q_fill_cnt;

  // ---- K/V local buffers (simple arrays, no ping-pong for now) ----
  logic signed [15:0] k_buf [TK][D];
  logic signed [15:0] v_buf [TK][D];
  logic [$clog2(TK*D/ELEMS_PER_BEAT):0] kv_fill_cnt;

  // ---- Row context (m, l, acc) ----
  logic signed [15:0] row_m   [TQ];
  logic [31:0]        row_l   [TQ];
  logic signed [63:0] row_acc [TQ][D];

  // ---- Compute engine state ----
  logic [$clog2(TQ)-1:0] comp_qpair;
  logic [$clog2(TK)-1:0] comp_kj;
  logic [$clog2(D)-1:0]  comp_d;
  logic signed [39:0]    dp_acc0;
  logic signed [39:0]    dp_acc1;
  logic signed [15:0]    score_q8_8_0;
  logic signed [15:0]    score_q8_8_1;

  // ---- Normalization / write-out state ----
  logic [$clog2(TQ)-1:0] norm_qi;
  logic [$clog2(D)-1:0]  norm_d;
  logic [31:0]           recip_val;
  logic [$clog2(TQ*D/ELEMS_PER_BEAT):0] o_write_cnt;

  // ---- O output buffer ----
  logic signed [15:0] o_buf [TQ][D];

  // Recip instance
  fa_recip_nr_q16_16 u_recip (
    .i_x_q16_16(row_l[norm_qi]),
    .o_recip_q16_16(recip_val)
  );

  // Exp instances for online softmax
  logic signed [15:0] exp_diff_old_in0, exp_diff_new_in0;
  logic signed [15:0] exp_diff_old_in1, exp_diff_new_in1;
  logic [15:0] exp_old_out0, exp_new_out0;
  logic [15:0] exp_old_out1, exp_new_out1;
  fa_exp_pwl_8seg_q1_15 u_exp_old0 (.i_x_q8_8(exp_diff_old_in0), .o_exp_q1_15(exp_old_out0));
  fa_exp_pwl_8seg_q1_15 u_exp_new0 (.i_x_q8_8(exp_diff_new_in0), .o_exp_q1_15(exp_new_out0));
  fa_exp_pwl_8seg_q1_15 u_exp_old1 (.i_x_q8_8(exp_diff_old_in1), .o_exp_q1_15(exp_old_out1));
  fa_exp_pwl_8seg_q1_15 u_exp_new1 (.i_x_q8_8(exp_diff_new_in1), .o_exp_q1_15(exp_new_out1));

  // Inner compute FSM
  typedef enum logic [3:0] {
    C_IDLE,
    C_DP_INIT,
    C_DP_RUN,
    C_SCORE_DONE,
    C_SOFTMAX_PREP,
    C_PV_ACC,
    C_PV_DONE,
    C_NEXT_KJ,
    C_NEXT_QI,
    C_DONE
  } comp_state_t;
  comp_state_t cs;

  logic comp_start, comp_done;
  logic signed [15:0] m_old0, m_new0;
  logic signed [15:0] m_old1, m_new1;
  logic [31:0] l_scaled0, l_term0, l_new_val0;
  logic [31:0] l_scaled1, l_term1, l_new_val1;
  logic [63:0] l_scaled_wide0;
  logic [63:0] l_scaled_wide1;
  logic signed [39:0] dp_partial_sum0;
  logic signed [39:0] dp_partial_sum1;

  always_comb begin
    m_old0 = row_m[comp_qpair];
    if (score_q8_8_0 > m_old0)
      m_new0 = score_q8_8_0;
    else
      m_new0 = m_old0;

    exp_diff_old_in0 = m_old0 - m_new0;
    exp_diff_new_in0 = score_q8_8_0 - m_new0;

    l_scaled_wide0 = row_l[comp_qpair] * exp_old_out0;
    l_scaled0 = l_scaled_wide0[46:15];
    l_term0 = {15'd0, exp_new_out0, 1'b0};
    l_new_val0 = l_scaled0 + l_term0;

    if (comp_qpair + 1 < TQ) begin
      m_old1 = row_m[comp_qpair + 1];
      if (score_q8_8_1 > m_old1)
        m_new1 = score_q8_8_1;
      else
        m_new1 = m_old1;

      exp_diff_old_in1 = m_old1 - m_new1;
      exp_diff_new_in1 = score_q8_8_1 - m_new1;

      l_scaled_wide1 = row_l[comp_qpair + 1] * exp_old_out1;
      l_scaled1 = l_scaled_wide1[46:15];
      l_term1 = {15'd0, exp_new_out1, 1'b0};
      l_new_val1 = l_scaled1 + l_term1;
    end else begin
      m_old1 = i_neg_large_q8_8;
      m_new1 = i_neg_large_q8_8;
      exp_diff_old_in1 = 16'sd0;
      exp_diff_new_in1 = 16'sd0;
      l_scaled_wide1 = 64'd0;
      l_scaled1 = 32'd0;
      l_term1 = 32'd0;
      l_new_val1 = 32'd0;
    end
  end

  always_comb begin
    dp_partial_sum0 = '0;
    dp_partial_sum1 = '0;
    for (int lane = 0; lane < DP_LANES; lane++) begin
      automatic int d_idx;
      d_idx = comp_d * DP_LANES + lane;
      dp_partial_sum0 = dp_partial_sum0 + 40'(q_buf[comp_qpair][d_idx]) * 40'(k_buf[comp_kj][d_idx]);
      if (comp_qpair + 1 < TQ)
        dp_partial_sum1 = dp_partial_sum1 + 40'(q_buf[comp_qpair + 1][d_idx]) * 40'(k_buf[comp_kj][d_idx]);
    end
  end

  // Scale mul: dp_acc -> score
  // Extract Q8.8 from 40-bit accumulator (which is in Q16.16 after multiply)
  // dp_acc is sum of (Q8.8 * Q8.8) = Q16.16, so shift >>8 gives Q8.8
  logic signed [15:0] dp_to_q8_8_0;
  logic signed [15:0] dp_to_q8_8_1;
  logic signed [31:0] dp_shifted0;
  logic signed [31:0] dp_shifted1;
  always_comb begin
    dp_shifted0 = dp_acc0[39:8]; // Q8.8 portion (with extra precision)
    dp_shifted1 = dp_acc1[39:8]; // Q8.8 portion (with extra precision)
  end
  fa_mul_sat_q8_8 u_score_scale0 (
    .i_a_q8_8(dp_shifted0[15:0]),
    .i_b_q8_8(i_scale_q8_8),
    .o_y_q8_8(dp_to_q8_8_0)
  );
  fa_mul_sat_q8_8 u_score_scale1 (
    .i_a_q8_8(dp_shifted1[15:0]),
    .i_b_q8_8(i_scale_q8_8),
    .o_y_q8_8(dp_to_q8_8_1)
  );

  // ---- Inner compute FSM ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs        <= C_IDLE;
      comp_qpair <= '0;
      comp_kj   <= '0;
      comp_d    <= '0;
      dp_acc0   <= '0;
      dp_acc1   <= '0;
      comp_done <= 1'b0;
      score_q8_8_0 <= '0;
      score_q8_8_1 <= '0;
    end else begin
      comp_done <= 1'b0;

      case (cs)
        C_IDLE: begin
          if (comp_start) begin
            comp_qpair <= '0;
            comp_kj <= '0;
            cs      <= C_DP_INIT;
          end
        end

        C_DP_INIT: begin
          dp_acc0 <= '0;
          dp_acc1 <= '0;
          comp_d <= '0;
          cs     <= C_DP_RUN;
        end

        C_DP_RUN: begin
          dp_acc0 <= dp_acc0 + dp_partial_sum0;
          dp_acc1 <= dp_acc1 + dp_partial_sum1;
          if (comp_d == DP_CHUNKS - 1)
            cs <= C_SCORE_DONE;
          else
            comp_d <= comp_d + 1'b1;
        end

        C_SCORE_DONE: begin
          // Apply scale
          score_q8_8_0 <= dp_to_q8_8_0;
          score_q8_8_1 <= dp_to_q8_8_1;
          // Apply causal mask
          if (i_causal_en) begin
            if ((q_tile_idx * TQ + comp_qpair) < (k_tile_idx * TK + comp_kj))
              score_q8_8_0 <= i_neg_large_q8_8;
            else
              score_q8_8_0 <= dp_to_q8_8_0;

            if ((comp_qpair + 1 < TQ) && ((q_tile_idx * TQ + comp_qpair + 1) < (k_tile_idx * TK + comp_kj)))
              score_q8_8_1 <= i_neg_large_q8_8;
            else
              score_q8_8_1 <= dp_to_q8_8_1;
          end
          cs <= C_SOFTMAX_PREP;
        end

        C_SOFTMAX_PREP: begin
          // Update row context: m, l
          row_m[comp_qpair] <= m_new0;
          row_l[comp_qpair] <= l_new_val0;
          if (comp_qpair + 1 < TQ) begin
            row_m[comp_qpair + 1] <= m_new1;
            row_l[comp_qpair + 1] <= l_new_val1;
          end

          // Update acc: rescale old + add P*V contribution
          for (int k = 0; k < D; k++) begin
            automatic logic signed [95:0] acc_sc;
            automatic logic signed [63:0] acc_old_sc;
            automatic logic signed [33:0] pv_mul;
            automatic logic signed [63:0] pv_term;
            acc_sc = row_acc[comp_qpair][k] * $signed({1'b0, exp_old_out0});
            acc_old_sc = acc_sc[78:15];
            pv_mul = $signed({1'b0, exp_new_out0}) * v_buf[comp_kj][k];
            pv_term = {{30{pv_mul[33]}}, pv_mul[33:0]} <<< 1;
            row_acc[comp_qpair][k] <= acc_old_sc + pv_term;

            if (comp_qpair + 1 < TQ) begin
              acc_sc = row_acc[comp_qpair + 1][k] * $signed({1'b0, exp_old_out1});
              acc_old_sc = acc_sc[78:15];
              pv_mul = $signed({1'b0, exp_new_out1}) * v_buf[comp_kj][k];
              pv_term = {{30{pv_mul[33]}}, pv_mul[33:0]} <<< 1;
              row_acc[comp_qpair + 1][k] <= acc_old_sc + pv_term;
            end
          end

          cs <= C_NEXT_KJ;
        end

        C_NEXT_KJ: begin
          if (comp_kj == TK - 1) begin
            comp_kj <= '0;
            cs      <= C_NEXT_QI;
          end else begin
            comp_kj <= comp_kj + 1'b1;
            cs      <= C_DP_INIT;
          end
        end

        C_NEXT_QI: begin
          if (comp_qpair >= TQ - ROW_PAR) begin
            cs <= C_DONE;
          end else begin
            comp_qpair <= comp_qpair + ROW_PAR;
            comp_kj <= '0;
            cs      <= C_DP_INIT;
          end
        end

        C_DONE: begin
          comp_done <= 1'b1;
          cs        <= C_IDLE;
        end

        default: cs <= C_IDLE;
      endcase
    end
  end

  // ---- Master FSM ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ms            <= S_IDLE;
      q_tile_idx    <= '0;
      k_tile_idx    <= '0;
      cycle_counter <= '0;
      q_fill_cnt    <= '0;
      kv_fill_cnt   <= '0;
      norm_qi       <= '0;
      norm_d        <= '0;
      o_write_cnt   <= '0;
      o_busy        <= 1'b0;
      o_done        <= 1'b0;
      o_error       <= 1'b0;
      comp_start    <= 1'b0;
      dma_rd_cmd_valid <= 1'b0;
      dma_wr_cmd_valid <= 1'b0;
      dma_wr_data_valid <= 1'b0;
    end else begin
      o_done     <= 1'b0;
      comp_start <= 1'b0;
      dma_rd_cmd_valid <= 1'b0;
      dma_wr_cmd_valid <= 1'b0;
      dma_wr_data_valid <= 1'b0;

      if (i_soft_reset) begin
        ms         <= S_IDLE;
        o_busy     <= 1'b0;
        o_error    <= 1'b0;
      end else begin

      case (ms)
        S_IDLE: begin
          if (i_start && !o_busy) begin
            o_busy        <= 1'b1;
            cycle_counter <= '0;
            q_tile_idx    <= '0;
            k_tile_idx    <= '0;
            ms            <= S_LOAD_Q;
            q_fill_cnt    <= '0;
          end
        end

        // -- Load Q tile via DMA --
        S_LOAD_Q: begin
          cycle_counter <= cycle_counter + 1'b1;
          if (q_fill_cnt == 0) begin
            // Issue DMA command for Q tile
            dma_rd_cmd_valid <= 1'b1;
            dma_rd_cmd_addr  <= i_q_base[31:0] + q_tile_idx * TQ * i_stride_bytes;
            dma_rd_cmd_len   <= BEATS_PER_TILE_Q - 1;
            if (dma_rd_cmd_ready) begin
              q_fill_cnt <= q_fill_cnt + 1'b1;
            end
          end else if (q_fill_cnt <= BEATS_PER_TILE_Q) begin
            // Receive Q data
            if (dma_rd_data_valid) begin
              for (int i = 0; i < ELEMS_PER_BEAT; i++) begin
                automatic int flat = (q_fill_cnt - 1) * ELEMS_PER_BEAT + i;
                q_buf[flat / D][flat % D] <= $signed(dma_rd_data[i*16 +: 16]);
              end
              q_fill_cnt <= q_fill_cnt + 1'b1;
              if (dma_rd_data_last || q_fill_cnt == BEATS_PER_TILE_Q)
                ms <= S_INIT_CONTEXT;
            end
          end
        end

        S_INIT_CONTEXT: begin
          cycle_counter <= cycle_counter + 1'b1;
          for (int r = 0; r < TQ; r++) begin
            row_m[r]   <= i_neg_large_q8_8;
            row_l[r]   <= 32'd0;
            for (int k = 0; k < D; k++)
              row_acc[r][k] <= 64'sd0;
          end
          k_tile_idx <= '0;
          ms         <= S_LOAD_K;
          kv_fill_cnt <= '0;
        end

        // -- Load K tile --
        S_LOAD_K: begin
          cycle_counter <= cycle_counter + 1'b1;
          if (kv_fill_cnt == 0) begin
            dma_rd_cmd_valid <= 1'b1;
            dma_rd_cmd_addr  <= i_k_base[31:0] + k_tile_idx * TK * i_stride_bytes;
            dma_rd_cmd_len   <= BEATS_PER_TILE_KV - 1;
            if (dma_rd_cmd_ready)
              kv_fill_cnt <= kv_fill_cnt + 1'b1;
          end else if (kv_fill_cnt <= BEATS_PER_TILE_KV) begin
            if (dma_rd_data_valid) begin
              for (int i = 0; i < ELEMS_PER_BEAT; i++) begin
                automatic int flat = (kv_fill_cnt - 1) * ELEMS_PER_BEAT + i;
                k_buf[flat / D][flat % D] <= $signed(dma_rd_data[i*16 +: 16]);
              end
              kv_fill_cnt <= kv_fill_cnt + 1'b1;
              if (dma_rd_data_last || kv_fill_cnt == BEATS_PER_TILE_KV) begin
                kv_fill_cnt <= '0;
                ms          <= S_LOAD_V;
              end
            end
          end
        end

        // -- Load V tile --
        S_LOAD_V: begin
          cycle_counter <= cycle_counter + 1'b1;
          if (kv_fill_cnt == 0) begin
            dma_rd_cmd_valid <= 1'b1;
            dma_rd_cmd_addr  <= i_v_base[31:0] + k_tile_idx * TK * i_stride_bytes;
            dma_rd_cmd_len   <= BEATS_PER_TILE_KV - 1;
            if (dma_rd_cmd_ready)
              kv_fill_cnt <= kv_fill_cnt + 1'b1;
          end else if (kv_fill_cnt <= BEATS_PER_TILE_KV) begin
            if (dma_rd_data_valid) begin
              for (int i = 0; i < ELEMS_PER_BEAT; i++) begin
                automatic int flat = (kv_fill_cnt - 1) * ELEMS_PER_BEAT + i;
                v_buf[flat / D][flat % D] <= $signed(dma_rd_data[i*16 +: 16]);
              end
              kv_fill_cnt <= kv_fill_cnt + 1'b1;
              if (dma_rd_data_last || kv_fill_cnt == BEATS_PER_TILE_KV) begin
                ms <= S_COMPUTE;
              end
            end
          end
        end

        // -- Tile compute --
        S_COMPUTE: begin
          cycle_counter <= cycle_counter + 1'b1;
          if (!comp_done && cs == C_IDLE) begin
            comp_start <= 1'b1;
          end
          if (comp_done) begin
            ms <= S_NEXT_K;
          end
        end

        S_NEXT_K: begin
          cycle_counter <= cycle_counter + 1'b1;
          if (k_tile_idx == NUM_K_TILES - 1) begin
            ms      <= S_NORMALIZE;
            norm_qi <= '0;
            norm_d  <= '0;
          end else begin
            k_tile_idx  <= k_tile_idx + 1'b1;
            kv_fill_cnt <= '0;
            ms          <= S_LOAD_K;
          end
        end

        // -- Final normalization: O[i][k] = acc[i][k] / l[i] --
        S_NORMALIZE: begin
          cycle_counter <= cycle_counter + 1'b1;
          // Normalize 4 elements per cycle
          for (int lane = 0; lane < NORM_LANES; lane++) begin
            automatic int d_idx;
            automatic logic [31:0] den;
            automatic logic signed [63:0] num;
            automatic logic signed [63:0] num_adj;
            automatic logic signed [63:0] norm_result;

            d_idx = norm_d + lane;
            if (d_idx < D) begin
              den = row_l[norm_qi];
              num = row_acc[norm_qi][d_idx];
              if (den == 32'd0) begin
                norm_result = (num >= 0) ? 64'sd32767 : -64'sd32768;
              end else begin
                if (num >= 0)
                  num_adj = num + $signed({1'b0, den[31:1]});
                else
                  num_adj = num - $signed({1'b0, den[31:1]});
                norm_result = num_adj / $signed({1'b0, den});
              end

              if (norm_result > 64'sd32767)
                o_buf[norm_qi][d_idx] <= 16'sd32767;
              else if (norm_result < -64'sd32768)
                o_buf[norm_qi][d_idx] <= -16'sd32768;
              else
                o_buf[norm_qi][d_idx] <= norm_result[15:0];
            end
          end

          if (norm_d >= D - NORM_LANES) begin
            norm_d <= '0;
            if (norm_qi == TQ - 1) begin
              ms          <= S_WRITE_O;
              o_write_cnt <= '0;
            end else begin
              norm_qi <= norm_qi + 1'b1;
            end
          end else begin
            norm_d <= norm_d + NORM_LANES;
          end
        end

        // -- Write O tile --
        S_WRITE_O: begin
          cycle_counter <= cycle_counter + 1'b1;
          if (o_write_cnt == 0) begin
            dma_wr_cmd_valid <= 1'b1;
            dma_wr_cmd_addr  <= i_o_base[31:0] + q_tile_idx * TQ * i_stride_bytes;
            dma_wr_cmd_len   <= BEATS_PER_TILE_Q - 1;
            if (dma_wr_cmd_ready)
              o_write_cnt <= o_write_cnt + 1'b1;
          end else if (o_write_cnt <= BEATS_PER_TILE_Q) begin
            dma_wr_data_valid <= 1'b1;
            for (int i = 0; i < ELEMS_PER_BEAT; i++) begin
              automatic int flat = (o_write_cnt - 1) * ELEMS_PER_BEAT + i;
              dma_wr_data[i*16 +: 16] <= o_buf[flat / D][flat % D];
            end
            dma_wr_data_last <= (o_write_cnt == BEATS_PER_TILE_Q);
            if (dma_wr_data_ready) begin
              o_write_cnt <= o_write_cnt + 1'b1;
              if (o_write_cnt == BEATS_PER_TILE_Q)
                ms <= S_NEXT_Q;
            end
          end
        end

        S_NEXT_Q: begin
          cycle_counter <= cycle_counter + 1'b1;
          if (q_tile_idx == NUM_Q_TILES - 1) begin
            ms <= S_DONE;
          end else begin
            q_tile_idx  <= q_tile_idx + 1'b1;
            q_fill_cnt  <= '0;
            ms          <= S_LOAD_Q;
          end
        end

        S_DONE: begin
          o_busy <= 1'b0;
          o_done <= 1'b1;
          ms     <= S_IDLE;
        end

        default: ms <= S_IDLE;
      endcase

      end // !soft_reset
    end
  end

  assign o_cycles = cycle_counter;

  // dma_rd_data_ready: accept data whenever we're in a load state
  assign dma_rd_data_ready = (ms == S_LOAD_Q || ms == S_LOAD_K || ms == S_LOAD_V);
endmodule
