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
  output logic                     dma_wr_data_last,

  // ---- Performance hooks ----
  output logic                     o_perf_ms_load_q,
  output logic                     o_perf_ms_init_context,
  output logic                     o_perf_ms_load_k,
  output logic                     o_perf_ms_load_v,
  output logic                     o_perf_ms_compute,
  output logic                     o_perf_ms_normalize,
  output logic                     o_perf_ms_write_o,
  output logic                     o_perf_ms_next_q,
  output logic                     o_perf_cs_dp_run,
  output logic                     o_perf_cs_score_done,
  output logic                     o_perf_cs_softmax_prep,
  output logic                     o_perf_comp_launch,
  output logic [1:0]               o_perf_active_rows,
  output logic                     o_perf_norm_recip_req,
  output logic                     o_perf_norm_recip_rsp
);

  // ---- Parameters ----
  localparam int NUM_Q_TILES = SEQ_LEN / TQ;  // 8
  localparam int NUM_K_TILES = SEQ_LEN / TK;  // 4
  localparam int ELEMS_PER_BEAT = BUS_W / 16; // 8
  localparam int BEATS_PER_ROW  = D / ELEMS_PER_BEAT; // 8
  localparam int BEATS_PER_TILE_KV = TK * BEATS_PER_ROW; // 512
  localparam int BEATS_PER_TILE_Q  = TQ * BEATS_PER_ROW; // 256
  localparam int DP_LANES = (D < 32) ? D : 32;
  localparam int DP_CHUNKS = D / DP_LANES;
  localparam int ROW_PAR = 2;
  localparam int NORM_LANES = 8;
  localparam int RECIP_LAT = 10;
  localparam int SOFTMAX_CTXS = 4;
  localparam int QPAIR_BATCH_ROWS = ROW_PAR * SOFTMAX_CTXS;
  localparam int QK_LAT = 8;
  localparam int QK_CHUNK_W = (DP_CHUNKS <= 1) ? 1 : $clog2(DP_CHUNKS);

  // ---- Master state machine ----
  typedef enum logic [3:0] {
    S_IDLE,
    S_LOAD_Q,         // DMA fetch Q tile
    S_INIT_CONTEXT,   // Init row context for new Q tile
    S_LOAD_K,         // DMA fetch K tile
    S_LOAD_V,         // DMA fetch V tile
    S_COMPUTE,        // Tile compute (QK^T + online softmax + PV)
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

  // ---- K/V local buffers (ping-pong) ----
  logic signed [15:0] k_buf0 [TK][D];
  logic signed [15:0] k_buf1 [TK][D];
  logic signed [15:0] v_buf0 [TK][D];
  logic signed [15:0] v_buf1 [TK][D];
  logic [$clog2(TK*D/ELEMS_PER_BEAT):0] kv_fill_cnt;
  logic active_bank;
  logic pref_target_bank;

  typedef enum logic [2:0] {
    PF_IDLE,
    PF_CMD_K,
    PF_DATA_K,
    PF_CMD_V,
    PF_DATA_V,
    PF_DONE
  } prefetch_state_t;
  prefetch_state_t pf_state;
  logic [$clog2(TK*D/ELEMS_PER_BEAT):0] pf_fill_cnt;

  // ---- Row context (m, l, acc) ----
  logic signed [15:0] row_m   [TQ];
  logic [31:0]        row_l   [TQ];
  logic signed [63:0] row_acc [TQ][D];

  // ---- Compute engine state ----
  logic [$clog2(TQ)-1:0] comp_batch_base;
  logic [1:0]           qk_issue_slot;
  logic [$clog2(TK)-1:0] qk_issue_kj;
  logic [QK_CHUNK_W-1:0] qk_issue_chunk;
  logic                  qk_issue_done;
  logic [SOFTMAX_CTXS-1:0] batch_done_mask;
  logic                  score_issue_valid;
  logic [1:0]            score_issue_slot;
  logic [$clog2(TK)-1:0] score_issue_kj;
  logic                  score_issue_row1_valid;
  logic signed [39:0]    score_issue_dp0;
  logic signed [39:0]    score_issue_dp1;
  logic                  ret_first_valid;
  logic [1:0]            ret_first_slot;
  logic [$clog2(TK)-1:0] ret_first_kj;
  logic                  ret_first_row1_valid;
  logic signed [39:0]    ret_first_sum0;
  logic signed [39:0]    ret_first_sum1;
  logic                  perf_cs_dp_run;
  logic                  perf_cs_score_done;
  logic                  perf_cs_softmax_prep;
  logic [SOFTMAX_CTXS-1:0] batch_done_next;

  // ---- Normalization / write-out state ----
  logic [$clog2(TQ)-1:0] norm_qi;
  logic [$clog2(D)-1:0]  norm_d;
  logic [$clog2(D)-1:0]  norm_recv_d;
  logic [$clog2(TQ*D/ELEMS_PER_BEAT):0] o_write_cnt;
  logic                  norm_recip_in_valid;
  logic                  norm_recip_out_valid;
  logic [31:0]           norm_recip_out_q16_16;
  logic                  norm_recip_pending;
  logic                  norm_row_ready;
  logic                  norm_row_den_zero;
  logic [31:0]           norm_row_recip;
  logic                  norm_issue_done;

  // ---- O output buffer ----
  logic signed [15:0] o_buf [TQ][D];

  // Inner compute FSM
  typedef enum logic [3:0] {
    C_IDLE,
    C_DP_RUN,
    C_SCORE_DONE,
    C_SOFTMAX_PREP,
    C_DONE
  } comp_state_t;
  comp_state_t cs;

  logic comp_start, comp_done;
  logic signed [39:0] dp_partial_sum0;
  logic signed [39:0] dp_partial_sum1;
  logic               dp_partial_valid;
  logic                     qk_issue_valid;
  logic [$clog2(TQ)-1:0]    qk_issue_row0;
  logic                     qk_issue_row1_valid;
  logic [$clog2(TQ)-1:0]    score_issue_row0;
  logic                     sm_row_start;
  logic                     sm_row_end;
  logic                     sm_issue_valid0;
  logic                     sm_issue_valid1;
  logic signed [15:0]       dp_q_row0 [D];
  logic signed [15:0]       dp_q_row1 [D];
  logic signed [15:0]       dp_k_row  [D];
  logic [DP_LANES*16-1:0]   dp_q0_chunk_flat;
  logic [DP_LANES*16-1:0]   dp_q1_chunk_flat;
  logic [DP_LANES*16-1:0]   dp_k_chunk_flat;
  logic signed [15:0]       sm_v_row    [D];
  logic                     sm_row0_valid;
  logic                     sm_row0_done;
  logic [1:0]               sm_row0_ctx_id;
  logic signed [15:0]       sm_row0_m_q8_8;
  logic [31:0]              sm_row0_l_q16_16;
  logic signed [31:0]       sm_row0_acc_q16_16 [D];
  logic                     sm_row1_valid;
  logic                     sm_row1_done;
  logic [1:0]               sm_row1_ctx_id;
  logic signed [15:0]       sm_row1_m_q8_8;
  logic [31:0]              sm_row1_l_q16_16;
  logic signed [31:0]       sm_row1_acc_q16_16 [D];
  logic                     qk_pipe_busy;
  logic                     batch_all_done;
  logic                     score_issue_fire;
  logic                     qk_tag_valid [QK_LAT];
  logic [1:0]               qk_tag_slot [QK_LAT];
  logic [$clog2(TK)-1:0]    qk_tag_kj [QK_LAT];
  logic                     qk_tag_chunk_last [QK_LAT];
  logic                     qk_tag_row1_valid [QK_LAT];
  logic signed [63:0]       norm_acc_chunk [NORM_LANES];
  logic signed [15:0]       norm_o_chunk   [NORM_LANES];
  logic                     norm_chunk_valid;
  logic [NORM_LANES*64-1:0] norm_acc_flat;
  logic [NORM_LANES*16-1:0] norm_o_flat;
  logic signed [31:0]       sm_init_acc0 [D];
  logic signed [31:0]       sm_init_acc1 [D];
  logic signed [31:0]       score_issue_shifted0;
  logic signed [31:0]       score_issue_shifted1;
  logic signed [15:0]       score_scaled0;
  logic signed [15:0]       score_scaled1;
  logic signed [15:0]       score_issue_q8_8_0;
  logic signed [15:0]       score_issue_q8_8_1;

  always_comb begin
    int row0_idx;
    int row1_idx;
    row0_idx = comp_batch_base + qk_issue_slot * ROW_PAR;
    row1_idx = row0_idx + 1;
    qk_issue_row0 = row0_idx[$clog2(TQ)-1:0];
    qk_issue_row1_valid = (row1_idx < TQ);
    row0_idx = comp_batch_base + score_issue_slot * ROW_PAR;
    row1_idx = row0_idx + 1;
    score_issue_row0 = row0_idx[$clog2(TQ)-1:0];
    sm_row_start = (score_issue_kj == '0);
    sm_row_end = (score_issue_kj == TK - 1);
    for (int k = 0; k < D; k++) begin
      dp_q_row0[k] = q_buf[qk_issue_row0][k];
      dp_q_row1[k] = qk_issue_row1_valid ? q_buf[qk_issue_row0 + 1][k] : 16'sd0;
      dp_k_row[k] = active_bank ? k_buf1[qk_issue_kj][k] : k_buf0[qk_issue_kj][k];
      sm_v_row[k] = active_bank ? v_buf1[score_issue_kj][k] : v_buf0[score_issue_kj][k];
      sm_init_acc0[k] = row_acc[score_issue_row0][k][31:0];
      sm_init_acc1[k] = score_issue_row1_valid ? row_acc[score_issue_row0 + 1][k][31:0] : 32'sd0;
    end
    for (int lane = 0; lane < DP_LANES; lane++) begin
      int d_idx;
      d_idx = qk_issue_chunk * DP_LANES + lane;
      if (d_idx < D) begin
        dp_q0_chunk_flat[lane*16 +: 16] = dp_q_row0[d_idx];
        dp_q1_chunk_flat[lane*16 +: 16] = dp_q_row1[d_idx];
        dp_k_chunk_flat[lane*16 +: 16] = dp_k_row[d_idx];
      end else begin
        dp_q0_chunk_flat[lane*16 +: 16] = 16'sd0;
        dp_q1_chunk_flat[lane*16 +: 16] = 16'sd0;
        dp_k_chunk_flat[lane*16 +: 16] = 16'sd0;
      end
    end
    for (int lane = 0; lane < NORM_LANES; lane++) begin
      if ((norm_d + lane) < D)
        norm_acc_chunk[lane] = row_acc[norm_qi][norm_d + lane];
      else
        norm_acc_chunk[lane] = 64'sd0;
      norm_acc_flat[lane*64 +: 64] = norm_acc_chunk[lane];
      norm_o_chunk[lane] = $signed(norm_o_flat[lane*16 +: 16]);
    end
    qk_pipe_busy = 1'b0;
    for (int st = 0; st < QK_LAT; st++)
      qk_pipe_busy |= qk_tag_valid[st];
    batch_done_next = batch_done_mask;
    if (sm_row0_valid && sm_row0_done)
      batch_done_next[sm_row0_ctx_id] = 1'b1;
    batch_all_done = &batch_done_next;
  end

  assign qk_issue_valid = (cs == C_DP_RUN) && !qk_issue_done;
  assign sm_issue_valid0 = score_issue_valid;
  assign sm_issue_valid1 = score_issue_valid && score_issue_row1_valid;
  assign score_issue_fire = score_issue_valid;

  fa_qk_dotprod_slice #(
    .LANES(DP_LANES)
  ) u_qk_dotprod_slice (
    .clk(clk),
    .rst_n(rst_n),
    .i_valid(qk_issue_valid),
    .i_row1_valid(qk_issue_row1_valid),
    .i_q0_chunk_q8_8(dp_q0_chunk_flat),
    .i_q1_chunk_q8_8(dp_q1_chunk_flat),
    .i_k_chunk_q8_8(dp_k_chunk_flat),
    .o_valid(dp_partial_valid),
    .o_partial_sum0(dp_partial_sum0),
    .o_partial_sum1(dp_partial_sum1)
  );

  // Scale mul: score issue datapath
  always_comb begin
    score_issue_shifted0 = score_issue_dp0[39:8];
    score_issue_shifted1 = score_issue_dp1[39:8];
    score_issue_q8_8_0 = score_scaled0;
    score_issue_q8_8_1 = score_scaled1;
    if (score_issue_valid && i_causal_en) begin
      if ((q_tile_idx * TQ + score_issue_row0) < (k_tile_idx * TK + score_issue_kj))
        score_issue_q8_8_0 = i_neg_large_q8_8;
      if (score_issue_row1_valid && ((q_tile_idx * TQ + score_issue_row0 + 1) < (k_tile_idx * TK + score_issue_kj)))
        score_issue_q8_8_1 = i_neg_large_q8_8;
    end
  end
  fa_mul_sat_q8_8 u_score_scale0 (
    .i_a_q8_8(score_issue_shifted0[15:0]),
    .i_b_q8_8(i_scale_q8_8),
    .o_y_q8_8(score_scaled0)
  );
  fa_mul_sat_q8_8 u_score_scale1 (
    .i_a_q8_8(score_issue_shifted1[15:0]),
    .i_b_q8_8(i_scale_q8_8),
    .o_y_q8_8(score_scaled1)
  );

  generate
    for (genvar gk = 0; gk < D; gk++) begin : gen_softmax_ctx
      if (gk == 0) begin : gen_lane0
        fa_online_softmax_ctx u_sm_ctx_row0 (
          .clk(clk),
          .rst_n(rst_n),
          .i_valid(sm_issue_valid0),
          .i_row_start(sm_row_start),
          .i_row_end(sm_row_end),
          .i_ctx_id(score_issue_slot),
          .i_init_m_q8_8(row_m[score_issue_row0]),
          .i_init_l_q16_16(row_l[score_issue_row0]),
          .i_init_acc_q16_16(sm_init_acc0[gk]),
          .i_score_q8_8(score_issue_q8_8_0),
          .i_value_q8_8(sm_v_row[gk]),
          .o_valid(sm_row0_valid),
          .o_row_done(sm_row0_done),
          .o_ctx_id(sm_row0_ctx_id),
          .o_m_q8_8(sm_row0_m_q8_8),
          .o_l_q16_16(sm_row0_l_q16_16),
          .o_acc_q16_16(sm_row0_acc_q16_16[gk])
        );

        fa_online_softmax_ctx u_sm_ctx_row1 (
          .clk(clk),
          .rst_n(rst_n),
          .i_valid(sm_issue_valid1),
          .i_row_start(sm_row_start),
          .i_row_end(sm_row_end),
          .i_ctx_id(score_issue_slot),
          .i_init_m_q8_8(row_m[score_issue_row0 + 1]),
          .i_init_l_q16_16(row_l[score_issue_row0 + 1]),
          .i_init_acc_q16_16(sm_init_acc1[gk]),
          .i_score_q8_8(score_issue_q8_8_1),
          .i_value_q8_8(sm_v_row[gk]),
          .o_valid(sm_row1_valid),
          .o_row_done(sm_row1_done),
          .o_ctx_id(sm_row1_ctx_id),
          .o_m_q8_8(sm_row1_m_q8_8),
          .o_l_q16_16(sm_row1_l_q16_16),
          .o_acc_q16_16(sm_row1_acc_q16_16[gk])
        );
      end else begin : gen_laneN
        fa_online_softmax_ctx u_sm_ctx_row0 (
          .clk(clk),
          .rst_n(rst_n),
          .i_valid(sm_issue_valid0),
          .i_row_start(sm_row_start),
          .i_row_end(sm_row_end),
          .i_ctx_id(score_issue_slot),
          .i_init_m_q8_8(row_m[score_issue_row0]),
          .i_init_l_q16_16(row_l[score_issue_row0]),
          .i_init_acc_q16_16(sm_init_acc0[gk]),
          .i_score_q8_8(score_issue_q8_8_0),
          .i_value_q8_8(sm_v_row[gk]),
          .o_valid(),
          .o_row_done(),
          .o_ctx_id(),
          .o_m_q8_8(),
          .o_l_q16_16(),
          .o_acc_q16_16(sm_row0_acc_q16_16[gk])
        );

        fa_online_softmax_ctx u_sm_ctx_row1 (
          .clk(clk),
          .rst_n(rst_n),
          .i_valid(sm_issue_valid1),
          .i_row_start(sm_row_start),
          .i_row_end(sm_row_end),
          .i_ctx_id(score_issue_slot),
          .i_init_m_q8_8(row_m[score_issue_row0 + 1]),
          .i_init_l_q16_16(row_l[score_issue_row0 + 1]),
          .i_init_acc_q16_16(sm_init_acc1[gk]),
          .i_score_q8_8(score_issue_q8_8_1),
          .i_value_q8_8(sm_v_row[gk]),
          .o_valid(),
          .o_row_done(),
          .o_ctx_id(),
          .o_m_q8_8(),
          .o_l_q16_16(),
          .o_acc_q16_16(sm_row1_acc_q16_16[gk])
        );
      end
    end
  endgenerate

  fa_recip_nr_q16_16 u_norm_recip (
    .clk(clk),
    .rst_n(rst_n),
    .i_valid(norm_recip_in_valid),
    .i_x_q16_16(row_l[norm_qi]),
    .o_valid(norm_recip_out_valid),
    .o_recip_q16_16(norm_recip_out_q16_16)
  );

  fa_o_normalize_block #(
    .LANES(NORM_LANES)
  ) u_o_normalize_block (
    .clk(clk),
    .rst_n(rst_n),
    .i_valid(ms == S_NORMALIZE && norm_row_ready && !norm_issue_done),
    .i_den_zero(norm_row_den_zero),
    .i_recip_q16_16(norm_row_recip),
    .i_acc_flat(norm_acc_flat),
    .o_valid(norm_chunk_valid),
    .o_data_flat(norm_o_flat)
  );

  // ---- Inner compute FSM ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs        <= C_IDLE;
      comp_batch_base <= '0;
      qk_issue_slot <= '0;
      qk_issue_kj <= '0;
      qk_issue_chunk <= '0;
      qk_issue_done <= 1'b0;
      batch_done_mask <= '0;
      score_issue_valid <= 1'b0;
      score_issue_slot <= '0;
      score_issue_kj <= '0;
      score_issue_row1_valid <= 1'b0;
      score_issue_dp0 <= '0;
      score_issue_dp1 <= '0;
      ret_first_valid <= 1'b0;
      ret_first_slot <= '0;
      ret_first_kj <= '0;
      ret_first_row1_valid <= 1'b0;
      ret_first_sum0 <= '0;
      ret_first_sum1 <= '0;
      perf_cs_dp_run <= 1'b0;
      perf_cs_score_done <= 1'b0;
      perf_cs_softmax_prep <= 1'b0;
      for (int st = 0; st < QK_LAT; st++) begin
        qk_tag_valid[st] <= 1'b0;
        qk_tag_slot[st] <= '0;
        qk_tag_kj[st] <= '0;
        qk_tag_chunk_last[st] <= 1'b0;
        qk_tag_row1_valid[st] <= 1'b0;
      end
      comp_done <= 1'b0;
    end else begin
      comp_done <= 1'b0;
      score_issue_valid <= 1'b0;
      perf_cs_dp_run <= 1'b0;
      perf_cs_score_done <= 1'b0;
      perf_cs_softmax_prep <= 1'b0;

      case (cs)
        C_IDLE: begin
          if (comp_start) begin
            comp_batch_base <= '0;
            qk_issue_slot <= '0;
            qk_issue_kj <= '0;
            qk_issue_chunk <= '0;
            qk_issue_done <= 1'b0;
            batch_done_mask <= '0;
            ret_first_valid <= 1'b0;
            for (int st = 0; st < QK_LAT; st++)
              qk_tag_valid[st] <= 1'b0;
            cs      <= C_DP_RUN;
          end
        end

        C_DP_RUN: begin
          perf_cs_dp_run <= qk_issue_valid || qk_pipe_busy || ret_first_valid;

          for (int st = QK_LAT-1; st > 0; st--) begin
            qk_tag_valid[st] <= qk_tag_valid[st-1];
            qk_tag_slot[st] <= qk_tag_slot[st-1];
            qk_tag_kj[st] <= qk_tag_kj[st-1];
            qk_tag_chunk_last[st] <= qk_tag_chunk_last[st-1];
            qk_tag_row1_valid[st] <= qk_tag_row1_valid[st-1];
          end
          qk_tag_valid[0] <= qk_issue_valid;
          qk_tag_slot[0] <= qk_issue_slot;
          qk_tag_kj[0] <= qk_issue_kj;
          qk_tag_chunk_last[0] <= (qk_issue_chunk == DP_CHUNKS - 1);
          qk_tag_row1_valid[0] <= qk_issue_row1_valid;

          if (!qk_issue_done) begin
            if (qk_issue_chunk == DP_CHUNKS - 1) begin
              qk_issue_chunk <= '0;
              if (qk_issue_slot == SOFTMAX_CTXS - 1) begin
                qk_issue_slot <= '0;
                if (qk_issue_kj == TK - 1)
                  qk_issue_done <= 1'b1;
                else
                  qk_issue_kj <= qk_issue_kj + 1'b1;
              end else begin
                qk_issue_slot <= qk_issue_slot + 1'b1;
              end
            end else begin
              qk_issue_chunk <= qk_issue_chunk + 1'b1;
            end
          end

          if (dp_partial_valid) begin
            if (qk_tag_chunk_last[QK_LAT-1] && !ret_first_valid) begin
              score_issue_valid <= 1'b1;
              score_issue_slot <= qk_tag_slot[QK_LAT-1];
              score_issue_kj <= qk_tag_kj[QK_LAT-1];
              score_issue_row1_valid <= qk_tag_row1_valid[QK_LAT-1];
              score_issue_dp0 <= dp_partial_sum0;
              score_issue_dp1 <= dp_partial_sum1;
              perf_cs_score_done <= 1'b1;
              perf_cs_softmax_prep <= 1'b1;
            end else if (!ret_first_valid) begin
              ret_first_valid <= 1'b1;
              ret_first_slot <= qk_tag_slot[QK_LAT-1];
              ret_first_kj <= qk_tag_kj[QK_LAT-1];
              ret_first_row1_valid <= qk_tag_row1_valid[QK_LAT-1];
              ret_first_sum0 <= dp_partial_sum0;
              ret_first_sum1 <= dp_partial_sum1;
            end else begin
              ret_first_valid <= 1'b0;
              score_issue_valid <= 1'b1;
              score_issue_slot <= ret_first_slot;
              score_issue_kj <= ret_first_kj;
              score_issue_row1_valid <= ret_first_row1_valid;
              score_issue_dp0 <= ret_first_sum0 + dp_partial_sum0;
              score_issue_dp1 <= ret_first_sum1 + dp_partial_sum1;
              perf_cs_score_done <= 1'b1;
              perf_cs_softmax_prep <= 1'b1;
            end
          end

          if (sm_row0_valid && sm_row0_done) begin
            row_m[comp_batch_base + sm_row0_ctx_id * ROW_PAR] <= sm_row0_m_q8_8;
            row_l[comp_batch_base + sm_row0_ctx_id * ROW_PAR] <= sm_row0_l_q16_16;
            for (int k = 0; k < D; k++)
              row_acc[comp_batch_base + sm_row0_ctx_id * ROW_PAR][k] <= {{32{sm_row0_acc_q16_16[k][31]}}, sm_row0_acc_q16_16[k]};
          end

          if (sm_row1_valid && sm_row1_done) begin
            row_m[comp_batch_base + sm_row1_ctx_id * ROW_PAR + 1] <= sm_row1_m_q8_8;
            row_l[comp_batch_base + sm_row1_ctx_id * ROW_PAR + 1] <= sm_row1_l_q16_16;
            for (int k = 0; k < D; k++)
              row_acc[comp_batch_base + sm_row1_ctx_id * ROW_PAR + 1][k] <= {{32{sm_row1_acc_q16_16[k][31]}}, sm_row1_acc_q16_16[k]};
          end

          batch_done_mask <= batch_done_next;
          if (&batch_done_next) begin
            if ((comp_batch_base + QPAIR_BATCH_ROWS) >= TQ) begin
              cs <= C_DONE;
            end else begin
              comp_batch_base <= comp_batch_base + QPAIR_BATCH_ROWS;
              qk_issue_slot <= '0;
              qk_issue_kj <= '0;
              qk_issue_chunk <= '0;
              qk_issue_done <= 1'b0;
              batch_done_mask <= '0;
              ret_first_valid <= 1'b0;
              score_issue_valid <= 1'b0;
              perf_cs_score_done <= 1'b0;
              perf_cs_softmax_prep <= 1'b0;
              for (int st = 0; st < QK_LAT; st++)
                qk_tag_valid[st] <= 1'b0;
            end
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
      active_bank   <= 1'b0;
      pref_target_bank <= 1'b1;
      pf_state      <= PF_IDLE;
      pf_fill_cnt   <= '0;
      norm_qi       <= '0;
      norm_d        <= '0;
      norm_recv_d   <= '0;
      norm_recip_in_valid <= 1'b0;
      norm_recip_pending  <= 1'b0;
      norm_row_ready      <= 1'b0;
      norm_row_den_zero   <= 1'b0;
      norm_row_recip      <= 32'd0;
      norm_issue_done     <= 1'b0;
      o_write_cnt   <= '0;
      o_busy        <= 1'b0;
      o_done        <= 1'b0;
      o_error       <= 1'b0;
      comp_start    <= 1'b0;
      dma_rd_cmd_valid <= 1'b0;
      dma_wr_cmd_valid <= 1'b0;
    end else begin
      o_done     <= 1'b0;
      comp_start <= 1'b0;
      dma_rd_cmd_valid <= 1'b0;
      dma_wr_cmd_valid <= 1'b0;
      norm_recip_in_valid <= 1'b0;

      if (i_soft_reset) begin
        ms         <= S_IDLE;
        o_busy     <= 1'b0;
        o_error    <= 1'b0;
        norm_recip_pending <= 1'b0;
        norm_row_ready     <= 1'b0;
        norm_row_den_zero  <= 1'b0;
        norm_row_recip     <= 32'd0;
      end else begin

      case (ms)
        S_IDLE: begin
          if (i_start && !o_busy) begin
            o_busy        <= 1'b1;
            cycle_counter <= '0;
            q_tile_idx    <= '0;
            k_tile_idx    <= '0;
            active_bank   <= 1'b0;
            pref_target_bank <= 1'b1;
            pf_state      <= PF_IDLE;
            pf_fill_cnt   <= '0;
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
                int flat;
                flat = (q_fill_cnt - 1) * ELEMS_PER_BEAT + i;
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
          active_bank <= 1'b0;
          pref_target_bank <= 1'b1;
          pf_state <= PF_IDLE;
          pf_fill_cnt <= '0;
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
                int flat;
                flat = (kv_fill_cnt - 1) * ELEMS_PER_BEAT + i;
                if (active_bank)
                  k_buf1[flat / D][flat % D] <= $signed(dma_rd_data[i*16 +: 16]);
                else
                  k_buf0[flat / D][flat % D] <= $signed(dma_rd_data[i*16 +: 16]);
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
                int flat;
                flat = (kv_fill_cnt - 1) * ELEMS_PER_BEAT + i;
                if (active_bank)
                  v_buf1[flat / D][flat % D] <= $signed(dma_rd_data[i*16 +: 16]);
                else
                  v_buf0[flat / D][flat % D] <= $signed(dma_rd_data[i*16 +: 16]);
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

          // Prefetch next K/V tile into the opposite bank while current tile computes.
          case (pf_state)
            PF_IDLE: begin
              if (k_tile_idx < NUM_K_TILES - 1) begin
                pref_target_bank <= ~active_bank;
                pf_fill_cnt <= '0;
                pf_state <= PF_CMD_K;
              end
            end

            PF_CMD_K: begin
              dma_rd_cmd_valid <= 1'b1;
              dma_rd_cmd_addr  <= i_k_base[31:0] + (k_tile_idx + 1) * TK * i_stride_bytes;
              dma_rd_cmd_len   <= BEATS_PER_TILE_KV - 1;
              if (dma_rd_cmd_ready) begin
                pf_fill_cnt <= 1;
                pf_state <= PF_DATA_K;
              end
            end

            PF_DATA_K: begin
              if (dma_rd_data_valid) begin
                for (int i = 0; i < ELEMS_PER_BEAT; i++) begin
                  int flat;
                  flat = (pf_fill_cnt - 1) * ELEMS_PER_BEAT + i;
                  if (pref_target_bank)
                    k_buf1[flat / D][flat % D] <= $signed(dma_rd_data[i*16 +: 16]);
                  else
                    k_buf0[flat / D][flat % D] <= $signed(dma_rd_data[i*16 +: 16]);
                end
                pf_fill_cnt <= pf_fill_cnt + 1'b1;
                if (dma_rd_data_last || pf_fill_cnt == BEATS_PER_TILE_KV) begin
                  pf_fill_cnt <= '0;
                  pf_state <= PF_CMD_V;
                end
              end
            end

            PF_CMD_V: begin
              dma_rd_cmd_valid <= 1'b1;
              dma_rd_cmd_addr  <= i_v_base[31:0] + (k_tile_idx + 1) * TK * i_stride_bytes;
              dma_rd_cmd_len   <= BEATS_PER_TILE_KV - 1;
              if (dma_rd_cmd_ready) begin
                pf_fill_cnt <= 1;
                pf_state <= PF_DATA_V;
              end
            end

            PF_DATA_V: begin
              if (dma_rd_data_valid) begin
                for (int i = 0; i < ELEMS_PER_BEAT; i++) begin
                  int flat;
                  flat = (pf_fill_cnt - 1) * ELEMS_PER_BEAT + i;
                  if (pref_target_bank)
                    v_buf1[flat / D][flat % D] <= $signed(dma_rd_data[i*16 +: 16]);
                  else
                    v_buf0[flat / D][flat % D] <= $signed(dma_rd_data[i*16 +: 16]);
                end
                pf_fill_cnt <= pf_fill_cnt + 1'b1;
                if (dma_rd_data_last || pf_fill_cnt == BEATS_PER_TILE_KV) begin
                  pf_state <= PF_DONE;
                end
              end
            end

            PF_DONE: begin
            end

            default: pf_state <= PF_IDLE;
          endcase

          if (!comp_done && cs == C_IDLE) begin
            comp_start <= 1'b1;
          end
          if (comp_done) begin
            if (k_tile_idx == NUM_K_TILES - 1) begin
              pf_state <= PF_IDLE;
              pf_fill_cnt <= '0;
              ms                <= S_NORMALIZE;
              norm_qi           <= '0;
              norm_d            <= '0;
              norm_recv_d       <= '0;
              norm_recip_pending <= 1'b0;
              norm_row_ready     <= 1'b0;
              norm_row_den_zero  <= 1'b0;
              norm_row_recip     <= 32'd0;
              norm_issue_done    <= 1'b0;
            end else if (pf_state == PF_DONE) begin
              k_tile_idx  <= k_tile_idx + 1'b1;
              active_bank <= pref_target_bank;
              if ((k_tile_idx + 1) == (NUM_K_TILES - 1)) begin
                pf_state <= PF_IDLE;
                pf_fill_cnt <= '0;
              end else begin
                pref_target_bank <= ~pref_target_bank;
                pf_fill_cnt <= '0;
                pf_state <= PF_CMD_K;
              end
            end
          end
        end

        // -- Final normalization: O[i][k] = acc[i][k] / l[i] --
        S_NORMALIZE: begin
          cycle_counter <= cycle_counter + 1'b1;
          if (!norm_row_ready) begin
            if (!norm_recip_pending) begin
              if (row_l[norm_qi] == 32'd0) begin
                norm_row_den_zero <= 1'b1;
                norm_row_ready    <= 1'b1;
                norm_row_recip    <= 32'd0;
                norm_d            <= '0;
                norm_recv_d       <= '0;
                norm_issue_done   <= 1'b0;
              end else begin
                norm_recip_in_valid <= 1'b1;
                norm_recip_pending  <= 1'b1;
                norm_row_den_zero   <= 1'b0;
              end
            end else if (norm_recip_out_valid) begin
              norm_recip_pending <= 1'b0;
              norm_row_ready     <= 1'b1;
              norm_row_recip     <= norm_recip_out_q16_16;
              norm_d             <= '0;
              norm_recv_d        <= '0;
              norm_issue_done    <= 1'b0;
            end
          end else begin
            if (!norm_issue_done) begin
              if (norm_d == (D - NORM_LANES))
                norm_issue_done <= 1'b1;
              else
                norm_d <= norm_d + NORM_LANES;
            end

            if (norm_chunk_valid) begin
              for (int lane = 0; lane < NORM_LANES; lane++) begin
                int d_idx;
                d_idx = norm_recv_d + lane;
                if (d_idx < D)
                  o_buf[norm_qi][d_idx] <= norm_o_chunk[lane];
              end

              if (norm_recv_d == (D - NORM_LANES)) begin
                norm_d            <= '0;
                norm_recv_d       <= '0;
                norm_row_ready    <= 1'b0;
                norm_row_den_zero <= 1'b0;
                norm_row_recip    <= 32'd0;
                norm_issue_done   <= 1'b0;
                if (norm_qi == TQ - 1) begin
                  ms          <= S_WRITE_O;
                  o_write_cnt <= '0;
                end else begin
                  norm_qi <= norm_qi + 1'b1;
                end
              end else begin
                norm_recv_d <= norm_recv_d + NORM_LANES;
              end
            end
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
            if (dma_wr_data_valid && dma_wr_data_ready) begin
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

  always_comb begin
    dma_wr_data_valid = 1'b0;
    dma_wr_data_last  = 1'b0;
    dma_wr_data       = '0;
    if ((ms == S_WRITE_O) && (o_write_cnt != 0) && (o_write_cnt <= BEATS_PER_TILE_Q)) begin
      dma_wr_data_valid = 1'b1;
      dma_wr_data_last  = (o_write_cnt == BEATS_PER_TILE_Q);
      for (int i = 0; i < ELEMS_PER_BEAT; i++) begin
        dma_wr_data[i*16 +: 16] = o_buf[((o_write_cnt - 1) * ELEMS_PER_BEAT + i) / D][((o_write_cnt - 1) * ELEMS_PER_BEAT + i) % D];
      end
    end
  end

  assign o_cycles = cycle_counter;

  assign o_perf_ms_load_q        = (ms == S_LOAD_Q);
  assign o_perf_ms_init_context  = (ms == S_INIT_CONTEXT);
  assign o_perf_ms_load_k        = (ms == S_LOAD_K);
  assign o_perf_ms_load_v        = (ms == S_LOAD_V);
  assign o_perf_ms_compute       = (ms == S_COMPUTE);
  assign o_perf_ms_normalize     = (ms == S_NORMALIZE);
  assign o_perf_ms_write_o       = (ms == S_WRITE_O);
  assign o_perf_ms_next_q        = (ms == S_NEXT_Q);

  assign o_perf_cs_dp_run        = perf_cs_dp_run;
  assign o_perf_cs_score_done    = perf_cs_score_done;
  assign o_perf_cs_softmax_prep  = perf_cs_softmax_prep;
  assign o_perf_comp_launch      = comp_start;
  assign o_perf_norm_recip_req   = norm_recip_in_valid;
  assign o_perf_norm_recip_rsp   = norm_recip_out_valid;

  always_comb begin
    if (score_issue_valid) begin
      o_perf_active_rows = score_issue_row1_valid ? 2'd2 : 2'd1;
    end else if (ms == S_COMPUTE) begin
      o_perf_active_rows = qk_issue_row1_valid ? 2'd2 : 2'd1;
    end else begin
      o_perf_active_rows = 2'd0;
    end
  end

  // dma_rd_data_ready: accept data whenever we're in a load state
  assign dma_rd_data_ready = (ms == S_LOAD_Q || ms == S_LOAD_K || ms == S_LOAD_V ||
                              (ms == S_COMPUTE && (pf_state == PF_DATA_K || pf_state == PF_DATA_V)));
endmodule
