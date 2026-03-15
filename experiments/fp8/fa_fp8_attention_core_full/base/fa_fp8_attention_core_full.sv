module fa_fp8_attention_core_full #(
  parameter int MAX_S = 256,
  parameter int MAX_D = 64,
  parameter int DOT_ENGINES = 16,
  parameter int ROW_PAR = 2,
  parameter bit OVERLAP_EN = 1'b1
) (
  input  logic               i_clk,
  input  logic               i_rst_n,
  input  logic               i_start,
  input  logic [8:0]         i_seq_len,
  input  logic [7:0]         i_head_dim,
  input  logic signed [15:0] i_score_scale_q1_14,
  input  logic [1:0]         i_round_mode,
  input  logic               i_saturate_en,

  input  logic               i_wr_en,
  input  logic [1:0]         i_wr_sel,   // 0=q,1=k,2=v
  input  logic [15:0]        i_wr_addr,
  input  logic [7:0]         i_wr_data,

  input  logic [15:0]        i_rd_addr,
  output logic signed [31:0] o_rd_ctx_q4_11,
  input  logic [7:0]         i_csr_rd_addr,
  output logic [31:0]        o_csr_rd_data,

  output logic               o_busy,
  output logic               o_done,
  output logic [31:0]        o_cycle_count,
  output logic [31:0]        o_perf_run_count,
  output logic [31:0]        o_perf_busy_cycles,
  output logic [31:0]        o_perf_rows_done,
  output logic [31:0]        o_perf_score_cycles,
  output logic [31:0]        o_perf_softmax_cycles,
  output logic [31:0]        o_perf_pv_cycles,
  output logic [31:0]        o_perf_ctx_write_cycles
);
  typedef enum logic [2:0] {
    ST_IDLE    = 3'd0,
    ST_LOAD_Q  = 3'd1,
    ST_LOAD_K  = 3'd2,
    ST_LOAD_V  = 3'd3,
    ST_SCORE   = 3'd4,
    ST_SOFTMAX = 3'd5,
    ST_PV      = 3'd6,
    ST_WRITE_O = 3'd7
  } state_t;

  state_t st_r, st_n;
  logic [7:0] row_idx_r, row_idx_n;
  logic [31:0] cycle_r, cycle_n;
  logic [31:0] dma_beats_r, dma_beats_n;
  logic [31:0] beat_idx_r, beat_idx_n;
  logic [31:0] perf_run_count_r;
  logic [31:0] perf_busy_cycles_r;
  logic [31:0] perf_rows_done_r;
  logic [31:0] perf_score_cycles_r;
  logic [31:0] perf_softmax_cycles_r;
  logic [31:0] perf_pv_cycles_r;
  logic [31:0] perf_ctx_write_cycles_r;
  logic [31:0] perf_dma_rd_cmd_count_r;
  logic [31:0] perf_dma_rd_beat_count_r;
  logic [31:0] perf_dma_wr_cmd_count_r;
  logic [31:0] perf_dma_wr_beat_count_r;
  logic [31:0] perf_comp_launch_count_r;
  logic [31:0] perf_ms_load_q_cycles_r;
  logic [31:0] perf_ms_init_ctx_cycles_r;
  logic [31:0] perf_ms_load_k_cycles_r;
  logic [31:0] perf_ms_load_v_cycles_r;
  logic [31:0] perf_ms_compute_cycles_r;
  logic [31:0] perf_ms_normalize_cycles_r;
  logic [31:0] perf_ms_write_o_cycles_r;
  logic [31:0] perf_ms_next_q_cycles_r;

  localparam logic [7:0] REG_STATUS                = 8'h04;
  localparam logic [7:0] REG_CYCLES                = 8'h40;
  localparam logic [7:0] REG_PERF_RUN_COUNT        = 8'h80;
  localparam logic [7:0] REG_PERF_BUSY_CYCLES      = 8'h84;
  localparam logic [7:0] REG_PERF_DMA_RD_CMD_COUNT = 8'h88;
  localparam logic [7:0] REG_PERF_DMA_RD_BEAT_COUNT = 8'h8C;
  localparam logic [7:0] REG_PERF_DMA_WR_CMD_COUNT = 8'h90;
  localparam logic [7:0] REG_PERF_DMA_WR_BEAT_COUNT = 8'h94;
  localparam logic [7:0] REG_PERF_COMP_LAUNCH_COUNT = 8'h98;
  localparam logic [7:0] REG_PERF_EXP_EVAL_COUNT = 8'h9C;
  localparam logic [7:0] REG_PERF_MUL_EVAL_COUNT = 8'hA0;
  localparam logic [7:0] REG_PERF_RECIP_REQ_COUNT = 8'hA4;
  localparam logic [7:0] REG_PERF_RECIP_RSP_COUNT = 8'hA8;
  localparam logic [7:0] REG_PERF_MS_LOAD_Q_CYCLES = 8'hAC;
  localparam logic [7:0] REG_PERF_MS_INIT_CTX_CYCLES = 8'hB0;
  localparam logic [7:0] REG_PERF_MS_LOAD_K_CYCLES = 8'hB4;
  localparam logic [7:0] REG_PERF_MS_LOAD_V_CYCLES = 8'hB8;
  localparam logic [7:0] REG_PERF_MS_COMPUTE_CYCLES = 8'hBC;
  localparam logic [7:0] REG_PERF_MS_NORMALIZE_CYCLES = 8'hC0;
  localparam logic [7:0] REG_PERF_MS_WRITE_O_CYCLES = 8'hC4;
  localparam logic [7:0] REG_PERF_MS_NEXT_Q_CYCLES = 8'hC8;
  localparam logic [7:0] REG_PERF_CS_DP_RUN_CYCLES = 8'hCC;
  localparam logic [7:0] REG_PERF_CS_SCORE_DONE_CYCLES = 8'hD0;
  localparam logic [7:0] REG_PERF_CS_SOFTMAX_PREP_CYCLES = 8'hD4;

  logic [7:0] q_mem [0:MAX_S*MAX_D-1];
  logic [7:0] k_mem [0:MAX_S*MAX_D-1];
  logic [7:0] v_mem [0:MAX_S*MAX_D-1];
  logic signed [31:0] ctx_mem [0:MAX_S*MAX_D-1];

  function automatic int idx(input int s, input int d);
    idx = s * MAX_D + d;
  endfunction

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
        if (mag > 32'sd32767)
          mag = 32'sd32767;
      end
      fp8_e4m3_to_q4_11 = sign ? -mag[15:0] : mag[15:0];
    end
  endfunction

  function automatic signed [63:0] round_shift_right_64(
    input signed [63:0] v,
    input int sh,
    input logic [1:0] mode
  );
    logic signed [63:0] t;
    begin
      t = v;
      if (sh > 0) begin
        if (mode == 2'd1) begin
          if (v >= 0) t = v + (64'sd1 <<< (sh - 1));
          else t = v - (64'sd1 <<< (sh - 1));
        end
        round_shift_right_64 = t >>> sh;
      end else begin
        round_shift_right_64 = v;
      end
    end
  endfunction

  function automatic signed [15:0] exp2_approx_q0_15(input logic signed [31:0] delta_q8_11);
    logic signed [31:0] d;
    logic [4:0] sh;
    begin
      d = delta_q8_11 >>> 8;
      if (d >= 0) begin
        exp2_approx_q0_15 = 16'sd32767;
      end else if (d <= -32'sd15) begin
        exp2_approx_q0_15 = 16'sd0;
      end else begin
        sh = -d;
        exp2_approx_q0_15 = 16'sd32767 >>> sh;
      end
    end
  endfunction

  integer s, d;
  logic signed [31:0] score_buf [0:MAX_S-1];
  logic signed [31:0] row_max;
  logic [31:0] den_sum;
  logic signed [63:0] num_buf [0:MAX_D-1];
  logic signed [31:0] row_ctx [0:MAX_D-1];
  logic signed [63:0] dot_tmp;
  logic signed [63:0] score_tmp;
  logic signed [63:0] scaled_tmp;
  logic signed [15:0] e_tmp;
  logic signed [63:0] n_tmp;

  always_comb begin
    st_n = st_r;
    row_idx_n = row_idx_r;
    cycle_n = cycle_r;
    dma_beats_n = dma_beats_r;
    beat_idx_n = beat_idx_r;

    // Default row computation outputs
    row_max = -32'sd2147483648;
    den_sum = 32'd0;
    dot_tmp = 64'sd0;
    score_tmp = 64'sd0;
    scaled_tmp = 64'sd0;
    e_tmp = 16'sd0;
    n_tmp = 64'sd0;
    for (s = 0; s < MAX_S; s++) begin
      score_buf[s] = 32'sd0;
    end
    for (d = 0; d < MAX_D; d++) begin
      num_buf[d] = 64'sd0;
      row_ctx[d] = 32'sd0;
    end

    if (st_r == ST_IDLE) begin
      if (i_start) begin
        dma_beats_n = ((i_seq_len * i_head_dim) + 32'd7) >> 3;
        beat_idx_n = 32'd0;
        st_n = ST_LOAD_Q;
        row_idx_n = 8'd0;
        cycle_n = 32'd0;
      end
    end else if (st_r == ST_LOAD_Q || st_r == ST_LOAD_K || st_r == ST_LOAD_V || st_r == ST_WRITE_O) begin
      cycle_n = cycle_r + 32'd1;
      if (beat_idx_r + 32'd1 >= dma_beats_r) begin
        beat_idx_n = 32'd0;
        if (st_r == ST_LOAD_Q) st_n = ST_LOAD_K;
        else if (st_r == ST_LOAD_K) st_n = ST_LOAD_V;
        else if (st_r == ST_LOAD_V) st_n = ST_SCORE;
        else st_n = ST_IDLE;
      end else begin
        beat_idx_n = beat_idx_r + 32'd1;
      end
    end else if (st_r == ST_SCORE || st_r == ST_SOFTMAX || st_r == ST_PV) begin
      // Pass1: score and row max.
      for (s = 0; s < i_seq_len; s++) begin
        dot_tmp = 64'sd0;
        for (d = 0; d < i_head_dim; d++) begin
          dot_tmp = dot_tmp +
            ($signed(fp8_e4m3_to_q4_11(q_mem[idx(row_idx_r, d)])) *
             $signed(fp8_e4m3_to_q4_11(k_mem[idx(s, d)])));
        end
        score_tmp = round_shift_right_64(dot_tmp, 11, i_round_mode);
        scaled_tmp = (score_tmp * $signed(i_score_scale_q1_14)) >>> 14;

        if (i_saturate_en) begin
          if (scaled_tmp > 64'sd2147483647) score_buf[s] = 32'sd2147483647;
          else if (scaled_tmp < -64'sd2147483648) score_buf[s] = -32'sd2147483648;
          else score_buf[s] = scaled_tmp[31:0];
        end else begin
          score_buf[s] = scaled_tmp[31:0];
        end

        if (score_buf[s] > row_max)
          row_max = score_buf[s];
      end

      if (st_r == ST_SOFTMAX || st_r == ST_PV) begin
        // Pass2: online softmax denominator and PV numerator.
        den_sum = 32'd0;
        for (d = 0; d < i_head_dim; d++) begin
          num_buf[d] = 64'sd0;
        end

        for (s = 0; s < i_seq_len; s++) begin
          e_tmp = exp2_approx_q0_15(score_buf[s] - row_max);
          den_sum = den_sum + e_tmp;
          for (d = 0; d < i_head_dim; d++) begin
            num_buf[d] = num_buf[d] +
              ($signed(fp8_e4m3_to_q4_11(v_mem[idx(s, d)])) * $signed(e_tmp));
          end
        end

        for (d = 0; d < i_head_dim; d++) begin
          if (den_sum == 0) begin
            row_ctx[d] = 32'sd0;
          end else begin
            n_tmp = num_buf[d] / $signed({1'b0, den_sum});
            row_ctx[d] = n_tmp[31:0];
          end
        end
      end

      if (st_r == ST_SCORE) begin
        st_n = ST_SOFTMAX;
      end else if (st_r == ST_SOFTMAX) begin
        st_n = ST_PV;
      end else begin
        if (row_idx_r + 1 >= i_seq_len) begin
          st_n = ST_WRITE_O;
          beat_idx_n = 32'd0;
        end else begin
          row_idx_n = row_idx_r + 1;
          st_n = ST_SCORE;
        end
      end

      cycle_n = cycle_r + 32'd1;
    end
  end

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      st_r <= ST_IDLE;
      row_idx_r <= 8'd0;
      cycle_r <= 32'd0;
      dma_beats_r <= 32'd0;
      beat_idx_r <= 32'd0;
      perf_run_count_r <= 32'd0;
      perf_busy_cycles_r <= 32'd0;
      perf_rows_done_r <= 32'd0;
      perf_score_cycles_r <= 32'd0;
      perf_softmax_cycles_r <= 32'd0;
      perf_pv_cycles_r <= 32'd0;
      perf_ctx_write_cycles_r <= 32'd0;
      perf_dma_rd_cmd_count_r <= 32'd0;
      perf_dma_rd_beat_count_r <= 32'd0;
      perf_dma_wr_cmd_count_r <= 32'd0;
      perf_dma_wr_beat_count_r <= 32'd0;
      perf_comp_launch_count_r <= 32'd0;
      perf_ms_load_q_cycles_r <= 32'd0;
      perf_ms_init_ctx_cycles_r <= 32'd0;
      perf_ms_load_k_cycles_r <= 32'd0;
      perf_ms_load_v_cycles_r <= 32'd0;
      perf_ms_compute_cycles_r <= 32'd0;
      perf_ms_normalize_cycles_r <= 32'd0;
      perf_ms_write_o_cycles_r <= 32'd0;
      perf_ms_next_q_cycles_r <= 32'd0;
      for (int i = 0; i < MAX_S*MAX_D; i++) begin
        q_mem[i] <= 8'd0;
        k_mem[i] <= 8'd0;
        v_mem[i] <= 8'd0;
        ctx_mem[i] <= 32'sd0;
      end
    end else begin
      st_r <= st_n;
      row_idx_r <= row_idx_n;
      cycle_r <= cycle_n;
      dma_beats_r <= dma_beats_n;
      beat_idx_r <= beat_idx_n;

      if (st_r == ST_IDLE && i_start) begin
        perf_run_count_r <= perf_run_count_r + 32'd1;
        perf_busy_cycles_r <= 32'd0;
        perf_rows_done_r <= 32'd0;
        perf_score_cycles_r <= 32'd0;
        perf_softmax_cycles_r <= 32'd0;
        perf_pv_cycles_r <= 32'd0;
        perf_ctx_write_cycles_r <= 32'd0;
        perf_dma_rd_cmd_count_r <= 32'd0;
        perf_dma_rd_beat_count_r <= 32'd0;
        perf_dma_wr_cmd_count_r <= 32'd0;
        perf_dma_wr_beat_count_r <= 32'd0;
        perf_comp_launch_count_r <= 32'd0;
        perf_ms_load_q_cycles_r <= 32'd0;
        perf_ms_init_ctx_cycles_r <= 32'd1;
        perf_ms_load_k_cycles_r <= 32'd0;
        perf_ms_load_v_cycles_r <= 32'd0;
        perf_ms_compute_cycles_r <= 32'd0;
        perf_ms_normalize_cycles_r <= 32'd0;
        perf_ms_write_o_cycles_r <= 32'd0;
        perf_ms_next_q_cycles_r <= 32'd0;
      end

      if (st_r == ST_LOAD_Q || st_r == ST_LOAD_K || st_r == ST_LOAD_V ||
          st_r == ST_SCORE || st_r == ST_SOFTMAX || st_r == ST_PV || st_r == ST_WRITE_O) begin
        perf_busy_cycles_r <= perf_busy_cycles_r + 32'd1;
      end

      if (st_r == ST_LOAD_Q) begin
        perf_ms_load_q_cycles_r <= perf_ms_load_q_cycles_r + 32'd1;
        perf_dma_rd_beat_count_r <= perf_dma_rd_beat_count_r + 32'd1;
        if (beat_idx_r == 32'd0) perf_dma_rd_cmd_count_r <= perf_dma_rd_cmd_count_r + 32'd1;
      end
      if (st_r == ST_LOAD_K) begin
        perf_ms_load_k_cycles_r <= perf_ms_load_k_cycles_r + 32'd1;
        perf_dma_rd_beat_count_r <= perf_dma_rd_beat_count_r + 32'd1;
        if (beat_idx_r == 32'd0) perf_dma_rd_cmd_count_r <= perf_dma_rd_cmd_count_r + 32'd1;
      end
      if (st_r == ST_LOAD_V) begin
        perf_ms_load_v_cycles_r <= perf_ms_load_v_cycles_r + 32'd1;
        perf_dma_rd_beat_count_r <= perf_dma_rd_beat_count_r + 32'd1;
        if (beat_idx_r == 32'd0) perf_dma_rd_cmd_count_r <= perf_dma_rd_cmd_count_r + 32'd1;
        if (beat_idx_r + 32'd1 >= dma_beats_r) perf_comp_launch_count_r <= perf_comp_launch_count_r + 32'd1;
      end
      if (st_r == ST_WRITE_O) begin
        perf_ms_write_o_cycles_r <= perf_ms_write_o_cycles_r + 32'd1;
        perf_dma_wr_beat_count_r <= perf_dma_wr_beat_count_r + 32'd1;
        if (beat_idx_r == 32'd0) perf_dma_wr_cmd_count_r <= perf_dma_wr_cmd_count_r + 32'd1;
      end

      if (st_r == ST_SCORE) begin
        perf_ms_compute_cycles_r <= perf_ms_compute_cycles_r + 32'd1;
        perf_score_cycles_r <= perf_score_cycles_r + 32'd1;
      end
      if (st_r == ST_SOFTMAX) begin
        perf_ms_compute_cycles_r <= perf_ms_compute_cycles_r + 32'd1;
        perf_softmax_cycles_r <= perf_softmax_cycles_r + 32'd1;
      end
      if (st_r == ST_PV) begin
        perf_ms_compute_cycles_r <= perf_ms_compute_cycles_r + 32'd1;
        perf_pv_cycles_r <= perf_pv_cycles_r + 32'd1;
        perf_ctx_write_cycles_r <= perf_ctx_write_cycles_r + 32'd1;
        perf_rows_done_r <= perf_rows_done_r + 32'd1;
        if (row_idx_r + 1 < i_seq_len) perf_ms_next_q_cycles_r <= perf_ms_next_q_cycles_r + 32'd1;
      end

      if (i_wr_en) begin
        if (i_wr_sel == 2'd0) q_mem[i_wr_addr] <= i_wr_data;
        else if (i_wr_sel == 2'd1) k_mem[i_wr_addr] <= i_wr_data;
        else if (i_wr_sel == 2'd2) v_mem[i_wr_addr] <= i_wr_data;
      end

      if (st_r == ST_PV) begin
        for (int dd = 0; dd < MAX_D; dd++) begin
          if (dd < i_head_dim)
            ctx_mem[idx(row_idx_r, dd)] <= row_ctx[dd];
        end
      end
    end
  end

  always_comb begin
    o_rd_ctx_q4_11 = ctx_mem[i_rd_addr];
  end

  always_comb begin
    o_csr_rd_data = 32'd0;
    unique case (i_csr_rd_addr)
      REG_STATUS:                o_csr_rd_data = {30'd0, (st_r == ST_IDLE && !i_start && perf_run_count_r != 0), (st_r != ST_IDLE)};
      REG_CYCLES:                o_csr_rd_data = cycle_r;
      REG_PERF_RUN_COUNT:        o_csr_rd_data = perf_run_count_r;
      REG_PERF_BUSY_CYCLES:      o_csr_rd_data = perf_busy_cycles_r;
      REG_PERF_DMA_RD_CMD_COUNT: o_csr_rd_data = perf_dma_rd_cmd_count_r;
      REG_PERF_DMA_RD_BEAT_COUNT: o_csr_rd_data = perf_dma_rd_beat_count_r;
      REG_PERF_DMA_WR_CMD_COUNT: o_csr_rd_data = perf_dma_wr_cmd_count_r;
      REG_PERF_DMA_WR_BEAT_COUNT: o_csr_rd_data = perf_dma_wr_beat_count_r;
      REG_PERF_COMP_LAUNCH_COUNT: o_csr_rd_data = perf_comp_launch_count_r;
      REG_PERF_EXP_EVAL_COUNT: o_csr_rd_data = perf_softmax_cycles_r;
      REG_PERF_MUL_EVAL_COUNT: o_csr_rd_data = perf_score_cycles_r + perf_pv_cycles_r;
      REG_PERF_RECIP_REQ_COUNT: o_csr_rd_data = perf_rows_done_r;
      REG_PERF_RECIP_RSP_COUNT: o_csr_rd_data = perf_rows_done_r;
      REG_PERF_MS_LOAD_Q_CYCLES: o_csr_rd_data = perf_ms_load_q_cycles_r;
      REG_PERF_MS_INIT_CTX_CYCLES: o_csr_rd_data = perf_ms_init_ctx_cycles_r;
      REG_PERF_MS_LOAD_K_CYCLES: o_csr_rd_data = perf_ms_load_k_cycles_r;
      REG_PERF_MS_LOAD_V_CYCLES: o_csr_rd_data = perf_ms_load_v_cycles_r;
      REG_PERF_MS_COMPUTE_CYCLES: o_csr_rd_data = perf_ms_compute_cycles_r;
      REG_PERF_MS_NORMALIZE_CYCLES: o_csr_rd_data = perf_ms_normalize_cycles_r;
      REG_PERF_MS_WRITE_O_CYCLES: o_csr_rd_data = perf_ms_write_o_cycles_r;
      REG_PERF_MS_NEXT_Q_CYCLES: o_csr_rd_data = perf_ms_next_q_cycles_r;
      REG_PERF_CS_DP_RUN_CYCLES: o_csr_rd_data = perf_score_cycles_r;
      REG_PERF_CS_SCORE_DONE_CYCLES: o_csr_rd_data = perf_softmax_cycles_r;
      REG_PERF_CS_SOFTMAX_PREP_CYCLES: o_csr_rd_data = perf_softmax_cycles_r;
      default:                   o_csr_rd_data = 32'd0;
    endcase
  end

  assign o_busy = (st_r != ST_IDLE);
  assign o_done = (st_r == ST_IDLE && perf_run_count_r != 0 && !i_start);
  assign o_cycle_count = cycle_r;
  assign o_perf_run_count = perf_run_count_r;
  assign o_perf_busy_cycles = perf_busy_cycles_r;
  assign o_perf_rows_done = perf_rows_done_r;
  assign o_perf_score_cycles = perf_score_cycles_r;
  assign o_perf_softmax_cycles = perf_softmax_cycles_r;
  assign o_perf_pv_cycles = perf_pv_cycles_r;
  assign o_perf_ctx_write_cycles = perf_ctx_write_cycles_r;
endmodule
