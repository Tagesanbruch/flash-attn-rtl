module fa_attention_core_bf16fp32 #(
  parameter int SEQ_LEN = 256,
  parameter int D = 64,
  parameter int TQ = 32,
  parameter int TK = 64,
  parameter int BUS_W = 128
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     i_start,
  input  logic                     i_soft_reset,
  input  logic                     i_causal_en,
  input  logic [31:0]              i_scale_fp32,
  input  logic [31:0]              i_neg_large_fp32,
  output logic                     o_busy,
  output logic                     o_done,
  output logic                     o_error,
  output logic [31:0]              o_cycles,
  input  logic [63:0]              i_q_base,
  input  logic [63:0]              i_k_base,
  input  logic [63:0]              i_v_base,
  input  logic [63:0]              i_o_base,
  input  logic [31:0]              i_stride_bytes,
  output logic                     dma_rd_cmd_valid,
  input  logic                     dma_rd_cmd_ready,
  output logic [31:0]              dma_rd_cmd_addr,
  output logic [15:0]              dma_rd_cmd_len,
  input  logic                     dma_rd_data_valid,
  output logic                     dma_rd_data_ready,
  input  logic [BUS_W-1:0]         dma_rd_data,
  input  logic                     dma_rd_data_last,
  output logic                     dma_wr_cmd_valid,
  input  logic                     dma_wr_cmd_ready,
  output logic [31:0]              dma_wr_cmd_addr,
  output logic [15:0]              dma_wr_cmd_len,
  output logic                     dma_wr_data_valid,
  input  logic                     dma_wr_data_ready,
  output logic [BUS_W-1:0]         dma_wr_data,
  output logic                     dma_wr_data_last,
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
  output logic                     o_perf_norm_recip_rsp,
  output logic                     o_perf_lane_idle,
  output logic                     o_perf_ctx_wait,
  output logic                     o_perf_tile_switch_bubbles
);
  localparam int NUM_Q_TILES = SEQ_LEN / TQ;
  localparam int NUM_K_TILES = SEQ_LEN / TK;
  localparam int ELEMS_PER_BEAT = BUS_W / 16;
  localparam int BEATS_PER_TILE_Q = TQ * D / ELEMS_PER_BEAT;
  localparam int BEATS_PER_TILE_KV = TK * D / ELEMS_PER_BEAT;

  typedef enum logic [3:0] {
    S_IDLE,
    S_LOAD_Q,
    S_INIT_CONTEXT,
    S_LOAD_K,
    S_LOAD_V,
    S_SCORE_DOT,
    S_SCORE_APPLY,
    S_ACC_UPDATE,
    S_NEXT_PAIR,
    S_NORMALIZE,
    S_WRITE_O,
    S_NEXT_Q,
    S_DONE
  } state_t;

  state_t ms;

  logic [15:0] q_buf [TQ][D];
  logic [15:0] k_buf [TK][D];
  logic [15:0] v_buf [TK][D];
  logic [15:0] o_buf [TQ][D];
  logic [31:0] row_m [TQ];
  logic [31:0] row_l [TQ];
  logic [31:0] row_inv [TQ];
  logic [31:0] row_acc [TQ][D];

  logic [31:0] cycle_counter;
  logic [$clog2(NUM_Q_TILES):0] q_tile_idx;
  logic [$clog2(NUM_K_TILES):0] k_tile_idx;
  logic [$clog2(TQ*D/ELEMS_PER_BEAT+2)-1:0] q_fill_cnt;
  logic [$clog2(TK*D/ELEMS_PER_BEAT+2)-1:0] kv_fill_cnt;
  logic [$clog2(TQ)-1:0] qi;
  logic [$clog2(TK)-1:0] kj;
  logic [$clog2(D)-1:0] d_idx;
  logic [$clog2(TQ)-1:0] norm_qi;
  logic [$clog2(D)-1:0] norm_d;
  logic [$clog2(TQ*D/ELEMS_PER_BEAT+2)-1:0] o_write_cnt;

  logic [31:0] score_acc_reg;
  logic [31:0] score_curr_reg;
  logic [31:0] exp_old_reg;
  logic [31:0] exp_new_reg;
  logic [31:0] exp_old_use;
  logic [31:0] exp_new_use;

  logic [15:0] q_cur_bf16_0;
  logic [15:0] q_cur_bf16_1;
  logic [15:0] q_cur_bf16_2;
  logic [15:0] q_cur_bf16_3;
  logic [15:0] k_cur_bf16_0;
  logic [15:0] k_cur_bf16_1;
  logic [15:0] k_cur_bf16_2;
  logic [15:0] k_cur_bf16_3;
  logic [15:0] v_cur_bf16_0;
  logic [15:0] v_cur_bf16_1;
  logic [15:0] v_cur_bf16_2;
  logic [15:0] v_cur_bf16_3;
  logic [31:0] q_cur_fp32_0;
  logic [31:0] q_cur_fp32_1;
  logic [31:0] q_cur_fp32_2;
  logic [31:0] q_cur_fp32_3;
  logic [31:0] k_cur_fp32_0;
  logic [31:0] k_cur_fp32_1;
  logic [31:0] k_cur_fp32_2;
  logic [31:0] k_cur_fp32_3;
  logic [31:0] v_cur_fp32_0;
  logic [31:0] v_cur_fp32_1;
  logic [31:0] v_cur_fp32_2;
  logic [31:0] v_cur_fp32_3;
  logic [31:0] prod_fp32_0;
  logic [31:0] prod_fp32_1;
  logic [31:0] prod_fp32_2;
  logic [31:0] prod_fp32_3;
  logic [31:0] dot_pair_sum01_fp32;
  logic [31:0] dot_pair_sum23_fp32;
  logic [31:0] dot_pair_sum_fp32;
  logic [31:0] dot_next_fp32;
  logic [31:0] score_scaled_fp32;
  logic [31:0] score_masked_fp32;
  logic [15:0] score_bf16;
  logic [31:0] m_new_fp32;
  logic [31:0] l_new_fp32;
  logic [31:0] acc_unused_fp32;
  logic [31:0] inv_l_new_fp32;
  logic [31:0] exp_old_fp32;
  logic [31:0] exp_new_fp32;
  logic [31:0] acc_scaled_fp32_0;
  logic [31:0] acc_scaled_fp32_1;
  logic [31:0] acc_scaled_fp32_2;
  logic [31:0] acc_scaled_fp32_3;
  logic [31:0] v_term_fp32_0;
  logic [31:0] v_term_fp32_1;
  logic [31:0] v_term_fp32_2;
  logic [31:0] v_term_fp32_3;
  logic [31:0] acc_next_fp32_0;
  logic [31:0] acc_next_fp32_1;
  logic [31:0] acc_next_fp32_2;
  logic [31:0] acc_next_fp32_3;
  logic [31:0] norm_out_fp32;
  logic [15:0] norm_out_bf16;
  logic [BUS_W-1:0] wr_pack;

  always_comb begin
    q_cur_bf16_0 = q_buf[qi][d_idx];
    k_cur_bf16_0 = k_buf[kj][d_idx];
    q_cur_bf16_1 = 16'd0;
    k_cur_bf16_1 = 16'd0;
    q_cur_bf16_2 = 16'd0;
    k_cur_bf16_2 = 16'd0;
    q_cur_bf16_3 = 16'd0;
    k_cur_bf16_3 = 16'd0;
    if (({1'b0, d_idx} + 1) < D) begin
      q_cur_bf16_1 = q_buf[qi][d_idx + 1'b1];
      k_cur_bf16_1 = k_buf[kj][d_idx + 1'b1];
    end
    if (({1'b0, d_idx} + 2) < D) begin
      q_cur_bf16_2 = q_buf[qi][d_idx + 2];
      k_cur_bf16_2 = k_buf[kj][d_idx + 2];
    end
    if (({1'b0, d_idx} + 3) < D) begin
      q_cur_bf16_3 = q_buf[qi][d_idx + 3];
      k_cur_bf16_3 = k_buf[kj][d_idx + 3];
    end
  end
  always_comb begin
    v_cur_bf16_0 = v_buf[kj][d_idx];
    v_cur_bf16_1 = 16'd0;
    v_cur_bf16_2 = 16'd0;
    v_cur_bf16_3 = 16'd0;
    if (({1'b0, d_idx} + 1) < D) begin
      v_cur_bf16_1 = v_buf[kj][d_idx + 1'b1];
    end
    if (({1'b0, d_idx} + 2) < D) begin
      v_cur_bf16_2 = v_buf[kj][d_idx + 2];
    end
    if (({1'b0, d_idx} + 3) < D) begin
      v_cur_bf16_3 = v_buf[kj][d_idx + 3];
    end
  end

  fa_bf16_to_fp32 u_q_widen_0 (.i_x_bf16(q_cur_bf16_0), .o_y_fp32(q_cur_fp32_0));
  fa_bf16_to_fp32 u_q_widen_1 (.i_x_bf16(q_cur_bf16_1), .o_y_fp32(q_cur_fp32_1));
  fa_bf16_to_fp32 u_q_widen_2 (.i_x_bf16(q_cur_bf16_2), .o_y_fp32(q_cur_fp32_2));
  fa_bf16_to_fp32 u_q_widen_3 (.i_x_bf16(q_cur_bf16_3), .o_y_fp32(q_cur_fp32_3));
  fa_bf16_to_fp32 u_k_widen_0 (.i_x_bf16(k_cur_bf16_0), .o_y_fp32(k_cur_fp32_0));
  fa_bf16_to_fp32 u_k_widen_1 (.i_x_bf16(k_cur_bf16_1), .o_y_fp32(k_cur_fp32_1));
  fa_bf16_to_fp32 u_k_widen_2 (.i_x_bf16(k_cur_bf16_2), .o_y_fp32(k_cur_fp32_2));
  fa_bf16_to_fp32 u_k_widen_3 (.i_x_bf16(k_cur_bf16_3), .o_y_fp32(k_cur_fp32_3));
  fa_bf16_to_fp32 u_v_widen_0 (.i_x_bf16(v_cur_bf16_0), .o_y_fp32(v_cur_fp32_0));
  fa_bf16_to_fp32 u_v_widen_1 (.i_x_bf16(v_cur_bf16_1), .o_y_fp32(v_cur_fp32_1));
  fa_bf16_to_fp32 u_v_widen_2 (.i_x_bf16(v_cur_bf16_2), .o_y_fp32(v_cur_fp32_2));
  fa_bf16_to_fp32 u_v_widen_3 (.i_x_bf16(v_cur_bf16_3), .o_y_fp32(v_cur_fp32_3));

  fa_fp32_mul_q16 u_dot_mul_0 (.i_a_fp32(q_cur_fp32_0), .i_b_fp32(k_cur_fp32_0), .o_y_fp32(prod_fp32_0));
  fa_fp32_mul_q16 u_dot_mul_1 (.i_a_fp32(q_cur_fp32_1), .i_b_fp32(k_cur_fp32_1), .o_y_fp32(prod_fp32_1));
  fa_fp32_mul_q16 u_dot_mul_2 (.i_a_fp32(q_cur_fp32_2), .i_b_fp32(k_cur_fp32_2), .o_y_fp32(prod_fp32_2));
  fa_fp32_mul_q16 u_dot_mul_3 (.i_a_fp32(q_cur_fp32_3), .i_b_fp32(k_cur_fp32_3), .o_y_fp32(prod_fp32_3));
  fa_fp32_add u_dot_pair_add01 (.i_a_fp32(prod_fp32_0), .i_b_fp32(prod_fp32_1), .o_y_fp32(dot_pair_sum01_fp32));
  fa_fp32_add u_dot_pair_add23 (.i_a_fp32(prod_fp32_2), .i_b_fp32(prod_fp32_3), .o_y_fp32(dot_pair_sum23_fp32));
  fa_fp32_add u_dot_pair_add (.i_a_fp32(dot_pair_sum01_fp32), .i_b_fp32(dot_pair_sum23_fp32), .o_y_fp32(dot_pair_sum_fp32));
  fa_fp32_add u_dot_add (.i_a_fp32(score_acc_reg), .i_b_fp32(dot_pair_sum_fp32), .o_y_fp32(dot_next_fp32));
  fa_fp32_mul_q16 u_score_scale (.i_a_fp32(score_curr_reg), .i_b_fp32(i_scale_fp32), .o_y_fp32(score_scaled_fp32));

  assign score_masked_fp32 = (i_causal_en && ((q_tile_idx * TQ + qi) < (k_tile_idx * TK + kj))) ? i_neg_large_fp32 : score_scaled_fp32;

  fa_fp32_to_bf16 u_score_downcast (.i_x_fp32(score_masked_fp32), .o_y_bf16(score_bf16));

  fa_fp32_softmax_update_scalar u_softmax_scalar (
    .i_row_start((k_tile_idx == 0) && (kj == 0)),
    .i_score_bf16(score_bf16),
    .i_value_bf16(16'd0),
    .i_m_old_fp32(row_m[qi]),
    .i_l_old_fp32(row_l[qi]),
    .i_acc_old_fp32(32'd0),
    .o_m_new_fp32(m_new_fp32),
    .o_l_new_fp32(l_new_fp32),
    .o_acc_new_fp32(acc_unused_fp32),
    .o_inv_l_new_fp32(inv_l_new_fp32),
    .o_exp_old_fp32(exp_old_fp32),
    .o_exp_new_fp32(exp_new_fp32)
  );

  assign exp_old_use = (ms == S_SCORE_APPLY) ? exp_old_fp32 : exp_old_reg;
  assign exp_new_use = (ms == S_SCORE_APPLY) ? exp_new_fp32 : exp_new_reg;

  fa_fp32_mul_q16 u_acc_scale_0 (.i_a_fp32(row_acc[qi][d_idx]), .i_b_fp32(exp_old_use), .o_y_fp32(acc_scaled_fp32_0));
  fa_fp32_mul_q16 u_acc_scale_1 (
    .i_a_fp32((((({1'b0, d_idx} + 1) < D)) ? row_acc[qi][d_idx + 1'b1] : 32'd0)),
    .i_b_fp32(exp_old_use),
    .o_y_fp32(acc_scaled_fp32_1)
  );
  fa_fp32_mul_q16 u_acc_scale_2 (
    .i_a_fp32((((({1'b0, d_idx} + 2) < D)) ? row_acc[qi][d_idx + 2] : 32'd0)),
    .i_b_fp32(exp_old_use),
    .o_y_fp32(acc_scaled_fp32_2)
  );
  fa_fp32_mul_q16 u_acc_scale_3 (
    .i_a_fp32((((({1'b0, d_idx} + 3) < D)) ? row_acc[qi][d_idx + 3] : 32'd0)),
    .i_b_fp32(exp_old_use),
    .o_y_fp32(acc_scaled_fp32_3)
  );
  fa_fp32_mul_q16 u_v_term_0 (.i_a_fp32(v_cur_fp32_0), .i_b_fp32(exp_new_use), .o_y_fp32(v_term_fp32_0));
  fa_fp32_mul_q16 u_v_term_1 (.i_a_fp32(v_cur_fp32_1), .i_b_fp32(exp_new_use), .o_y_fp32(v_term_fp32_1));
  fa_fp32_mul_q16 u_v_term_2 (.i_a_fp32(v_cur_fp32_2), .i_b_fp32(exp_new_use), .o_y_fp32(v_term_fp32_2));
  fa_fp32_mul_q16 u_v_term_3 (.i_a_fp32(v_cur_fp32_3), .i_b_fp32(exp_new_use), .o_y_fp32(v_term_fp32_3));
  fa_fp32_add u_acc_add_0 (
    .i_a_fp32(((k_tile_idx == 0) && (kj == 0)) ? 32'd0 : acc_scaled_fp32_0),
    .i_b_fp32(v_term_fp32_0),
    .o_y_fp32(acc_next_fp32_0)
  );
  fa_fp32_add u_acc_add_1 (
    .i_a_fp32(((k_tile_idx == 0) && (kj == 0)) ? 32'd0 : acc_scaled_fp32_1),
    .i_b_fp32(v_term_fp32_1),
    .o_y_fp32(acc_next_fp32_1)
  );
  fa_fp32_add u_acc_add_2 (
    .i_a_fp32(((k_tile_idx == 0) && (kj == 0)) ? 32'd0 : acc_scaled_fp32_2),
    .i_b_fp32(v_term_fp32_2),
    .o_y_fp32(acc_next_fp32_2)
  );
  fa_fp32_add u_acc_add_3 (
    .i_a_fp32(((k_tile_idx == 0) && (kj == 0)) ? 32'd0 : acc_scaled_fp32_3),
    .i_b_fp32(v_term_fp32_3),
    .o_y_fp32(acc_next_fp32_3)
  );
  fa_fp32_mul_q16 u_norm_mul (.i_a_fp32(row_acc[norm_qi][norm_d]), .i_b_fp32(row_inv[norm_qi]), .o_y_fp32(norm_out_fp32));
  fa_fp32_to_bf16 u_norm_downcast (.i_x_fp32(norm_out_fp32), .o_y_bf16(norm_out_bf16));

  assign dma_rd_data_ready = 1'b1;
  assign o_cycles = cycle_counter;
  assign o_error = 1'b0;

  assign o_perf_ms_load_q = (ms == S_LOAD_Q);
  assign o_perf_ms_init_context = (ms == S_INIT_CONTEXT);
  assign o_perf_ms_load_k = (ms == S_LOAD_K);
  assign o_perf_ms_load_v = (ms == S_LOAD_V);
  assign o_perf_ms_compute = (ms == S_SCORE_DOT) || (ms == S_SCORE_APPLY) || (ms == S_ACC_UPDATE) || (ms == S_NEXT_PAIR);
  assign o_perf_ms_normalize = (ms == S_NORMALIZE);
  assign o_perf_ms_write_o = (ms == S_WRITE_O);
  assign o_perf_ms_next_q = (ms == S_NEXT_Q);
  assign o_perf_cs_dp_run = (ms == S_SCORE_DOT);
  assign o_perf_cs_score_done = (ms == S_SCORE_APPLY);
  assign o_perf_cs_softmax_prep = (ms == S_ACC_UPDATE);
  assign o_perf_comp_launch = (ms == S_SCORE_DOT) && (d_idx == 0);
  assign o_perf_active_rows = ((ms == S_SCORE_DOT) || (ms == S_ACC_UPDATE) || (ms == S_NORMALIZE)) ? 2'd1 : 2'd0;
  assign o_perf_norm_recip_req = (ms == S_SCORE_APPLY);
  assign o_perf_norm_recip_rsp = (ms == S_SCORE_APPLY);
    assign o_perf_lane_idle =
        ((ms == S_SCORE_DOT) && ((({1'b0, d_idx} + 3) >= D))) ||
      ((ms == S_ACC_UPDATE) && ((({1'b0, d_idx} + 3) >= D)));
    assign o_perf_ctx_wait = 1'b0;
    assign o_perf_tile_switch_bubbles =
        (ms == S_ACC_UPDATE) && ((({1'b0, d_idx} + 4) >= D)) && (kj == TK - 1) && (qi == TQ - 1) && (k_tile_idx != NUM_K_TILES - 1);

  always_comb begin
    dma_rd_cmd_valid = 1'b0;
    dma_rd_cmd_addr = 32'd0;
    dma_rd_cmd_len = 16'd0;
    dma_wr_cmd_valid = 1'b0;
    dma_wr_cmd_addr = 32'd0;
    dma_wr_cmd_len = 16'd0;
    dma_wr_data_valid = 1'b0;
    dma_wr_data = '0;
    dma_wr_data_last = 1'b0;
    wr_pack = '0;

    if ((ms == S_LOAD_Q) && (q_fill_cnt == 0)) begin
      dma_rd_cmd_valid = 1'b1;
      dma_rd_cmd_addr = i_q_base[31:0] + q_tile_idx * TQ * i_stride_bytes;
      dma_rd_cmd_len = BEATS_PER_TILE_Q - 1;
    end else if ((ms == S_LOAD_K) && (kv_fill_cnt == 0)) begin
      dma_rd_cmd_valid = 1'b1;
      dma_rd_cmd_addr = i_k_base[31:0] + k_tile_idx * TK * i_stride_bytes;
      dma_rd_cmd_len = BEATS_PER_TILE_KV - 1;
    end else if ((ms == S_LOAD_V) && (kv_fill_cnt == 0)) begin
      dma_rd_cmd_valid = 1'b1;
      dma_rd_cmd_addr = i_v_base[31:0] + k_tile_idx * TK * i_stride_bytes;
      dma_rd_cmd_len = BEATS_PER_TILE_KV - 1;
    end else if ((ms == S_WRITE_O) && (o_write_cnt == 0)) begin
      dma_wr_cmd_valid = 1'b1;
      dma_wr_cmd_addr = i_o_base[31:0] + q_tile_idx * TQ * i_stride_bytes;
      dma_wr_cmd_len = BEATS_PER_TILE_Q - 1;
    end else if ((ms == S_WRITE_O) && (o_write_cnt > 0) && (o_write_cnt <= BEATS_PER_TILE_Q)) begin
      for (int e = 0; e < ELEMS_PER_BEAT; e++) begin
        wr_pack[e*16 +: 16] = o_buf[((o_write_cnt - 1) * ELEMS_PER_BEAT + e) / D][((o_write_cnt - 1) * ELEMS_PER_BEAT + e) % D];
      end
      dma_wr_data_valid = 1'b1;
      dma_wr_data = wr_pack;
      dma_wr_data_last = (o_write_cnt == BEATS_PER_TILE_Q);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ms <= S_IDLE;
      q_tile_idx <= '0;
      k_tile_idx <= '0;
      q_fill_cnt <= '0;
      kv_fill_cnt <= '0;
      qi <= '0;
      kj <= '0;
      d_idx <= '0;
      norm_qi <= '0;
      norm_d <= '0;
      o_write_cnt <= '0;
      cycle_counter <= '0;
      o_busy <= 1'b0;
      o_done <= 1'b0;
      score_acc_reg <= 32'd0;
      score_curr_reg <= 32'd0;
      exp_old_reg <= 32'd0;
      exp_new_reg <= 32'd0;
    end else begin
      o_done <= 1'b0;
      if (i_soft_reset) begin
        ms <= S_IDLE;
        o_busy <= 1'b0;
        cycle_counter <= '0;
      end else begin
        if (ms != S_IDLE) begin
          cycle_counter <= cycle_counter + 1'b1;
        end
        case (ms)
          S_IDLE: begin
            cycle_counter <= '0;
            if (i_start && !o_busy) begin
              o_busy <= 1'b1;
              q_tile_idx <= '0;
              q_fill_cnt <= '0;
              ms <= S_LOAD_Q;
            end
          end
          S_LOAD_Q: begin
            if (q_fill_cnt == 0) begin
              if (dma_rd_cmd_ready)
                q_fill_cnt <= 1;
            end else if (dma_rd_data_valid) begin
              for (int i = 0; i < ELEMS_PER_BEAT; i++) begin
                q_buf[((q_fill_cnt - 1) * ELEMS_PER_BEAT + i) / D][((q_fill_cnt - 1) * ELEMS_PER_BEAT + i) % D] <= dma_rd_data[i*16 +: 16];
              end
              if (dma_rd_data_last || (q_fill_cnt == BEATS_PER_TILE_Q)) begin
                ms <= S_INIT_CONTEXT;
              end
              q_fill_cnt <= q_fill_cnt + 1'b1;
            end
          end
          S_INIT_CONTEXT: begin
            for (int r = 0; r < TQ; r++) begin
              row_m[r] <= 32'd0;
              row_l[r] <= 32'd0;
              row_inv[r] <= 32'd0;
              for (int c = 0; c < D; c++) begin
                row_acc[r][c] <= 32'd0;
              end
            end
            k_tile_idx <= '0;
            kv_fill_cnt <= '0;
            ms <= S_LOAD_K;
          end
          S_LOAD_K: begin
            if (kv_fill_cnt == 0) begin
              if (dma_rd_cmd_ready)
                kv_fill_cnt <= 1;
            end else if (dma_rd_data_valid) begin
              for (int i = 0; i < ELEMS_PER_BEAT; i++) begin
                k_buf[((kv_fill_cnt - 1) * ELEMS_PER_BEAT + i) / D][((kv_fill_cnt - 1) * ELEMS_PER_BEAT + i) % D] <= dma_rd_data[i*16 +: 16];
              end
              if (dma_rd_data_last || (kv_fill_cnt == BEATS_PER_TILE_KV)) begin
                kv_fill_cnt <= '0;
                ms <= S_LOAD_V;
              end else begin
                kv_fill_cnt <= kv_fill_cnt + 1'b1;
              end
            end
          end
          S_LOAD_V: begin
            if (kv_fill_cnt == 0) begin
              if (dma_rd_cmd_ready)
                kv_fill_cnt <= 1;
            end else if (dma_rd_data_valid) begin
              for (int i = 0; i < ELEMS_PER_BEAT; i++) begin
                v_buf[((kv_fill_cnt - 1) * ELEMS_PER_BEAT + i) / D][((kv_fill_cnt - 1) * ELEMS_PER_BEAT + i) % D] <= dma_rd_data[i*16 +: 16];
              end
              if (dma_rd_data_last || (kv_fill_cnt == BEATS_PER_TILE_KV)) begin
                qi <= '0;
                kj <= '0;
                d_idx <= '0;
                score_acc_reg <= 32'd0;
                ms <= S_SCORE_DOT;
              end else begin
                kv_fill_cnt <= kv_fill_cnt + 1'b1;
              end
            end
          end
          S_SCORE_DOT: begin
            score_acc_reg <= (d_idx == 0) ? dot_pair_sum_fp32 : dot_next_fp32;
            if (({1'b0, d_idx} + 4) >= D) begin
              score_curr_reg <= (d_idx == 0) ? dot_pair_sum_fp32 : dot_next_fp32;
              d_idx <= '0;
              ms <= S_SCORE_APPLY;
            end else begin
              d_idx <= d_idx + 4;
            end
          end
          S_SCORE_APPLY: begin
            row_m[qi] <= m_new_fp32;
            row_l[qi] <= l_new_fp32;
            row_inv[qi] <= inv_l_new_fp32;
            exp_old_reg <= exp_old_fp32;
            exp_new_reg <= exp_new_fp32;
            row_acc[qi][0] <= acc_next_fp32_0;
            if (D > 1)
              row_acc[qi][1] <= acc_next_fp32_1;
            if (D > 2)
              row_acc[qi][2] <= acc_next_fp32_2;
            if (D > 3)
              row_acc[qi][3] <= acc_next_fp32_3;
            if (D <= 4) begin
              d_idx <= '0;
              score_acc_reg <= 32'd0;
              if (kj == TK - 1) begin
                kj <= '0;
                if (qi == TQ - 1) begin
                  if (k_tile_idx == NUM_K_TILES - 1) begin
                    norm_qi <= '0;
                    norm_d <= '0;
                    ms <= S_NORMALIZE;
                  end else begin
                    k_tile_idx <= k_tile_idx + 1'b1;
                    kv_fill_cnt <= '0;
                    ms <= S_LOAD_K;
                  end
                end else begin
                  qi <= qi + 1'b1;
                  ms <= S_SCORE_DOT;
                end
              end else begin
                kj <= kj + 1'b1;
                ms <= S_SCORE_DOT;
              end
            end else begin
              d_idx <= 4;
              ms <= S_ACC_UPDATE;
            end
          end
          S_ACC_UPDATE: begin
            row_acc[qi][d_idx] <= acc_next_fp32_0;
            if (({1'b0, d_idx} + 1) < D)
              row_acc[qi][d_idx + 1'b1] <= acc_next_fp32_1;
            if (({1'b0, d_idx} + 2) < D)
              row_acc[qi][d_idx + 2] <= acc_next_fp32_2;
            if (({1'b0, d_idx} + 3) < D)
              row_acc[qi][d_idx + 3] <= acc_next_fp32_3;
            if (({1'b0, d_idx} + 4) >= D) begin
              d_idx <= '0;
              score_acc_reg <= 32'd0;
              if (kj == TK - 1) begin
                kj <= '0;
                if (qi == TQ - 1) begin
                  if (k_tile_idx == NUM_K_TILES - 1) begin
                    norm_qi <= '0;
                    norm_d <= '0;
                    ms <= S_NORMALIZE;
                  end else begin
                    k_tile_idx <= k_tile_idx + 1'b1;
                    kv_fill_cnt <= '0;
                    ms <= S_LOAD_K;
                  end
                end else begin
                  qi <= qi + 1'b1;
                  ms <= S_SCORE_DOT;
                end
              end else begin
                kj <= kj + 1'b1;
                ms <= S_SCORE_DOT;
              end
            end else begin
              d_idx <= d_idx + 4;
            end
          end
          S_NEXT_PAIR: begin
            score_acc_reg <= 32'd0;
            if (kj == TK - 1) begin
              kj <= '0;
              if (qi == TQ - 1) begin
                if (k_tile_idx == NUM_K_TILES - 1) begin
                  norm_qi <= '0;
                  norm_d <= '0;
                  ms <= S_NORMALIZE;
                end else begin
                  k_tile_idx <= k_tile_idx + 1'b1;
                  kv_fill_cnt <= '0;
                  ms <= S_LOAD_K;
                end
              end else begin
                qi <= qi + 1'b1;
                ms <= S_SCORE_DOT;
              end
            end else begin
              kj <= kj + 1'b1;
              ms <= S_SCORE_DOT;
            end
          end
          S_NORMALIZE: begin
            o_buf[norm_qi][norm_d] <= norm_out_bf16;
            if (norm_d == D - 1) begin
              norm_d <= '0;
              if (norm_qi == TQ - 1) begin
                o_write_cnt <= '0;
                ms <= S_WRITE_O;
              end else begin
                norm_qi <= norm_qi + 1'b1;
              end
            end else begin
              norm_d <= norm_d + 1'b1;
            end
          end
          S_WRITE_O: begin
            if (o_write_cnt == 0) begin
              if (dma_wr_cmd_ready)
                o_write_cnt <= 1;
            end else if (dma_wr_data_ready) begin
              if (o_write_cnt == BEATS_PER_TILE_Q) begin
                ms <= S_NEXT_Q;
              end
              o_write_cnt <= o_write_cnt + 1'b1;
            end
          end
          S_NEXT_Q: begin
            if (q_tile_idx == NUM_Q_TILES - 1) begin
              ms <= S_DONE;
            end else begin
              q_tile_idx <= q_tile_idx + 1'b1;
              q_fill_cnt <= '0;
              ms <= S_LOAD_Q;
            end
          end
          S_DONE: begin
            o_busy <= 1'b0;
            o_done <= 1'b1;
            ms <= S_IDLE;
          end
          default: ms <= S_IDLE;
        endcase
      end
    end
  end
endmodule
