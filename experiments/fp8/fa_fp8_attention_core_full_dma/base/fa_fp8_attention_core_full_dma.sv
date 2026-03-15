module fa_fp8_attention_core_full_dma #(
  parameter int MAX_S = 256,
  parameter int MAX_D = 64,
  parameter int TQ = 32,
  parameter int TK = 64,
  parameter int BUS_W = 128
) (
  input  logic               i_clk,
  input  logic               i_rst_n,
  input  logic               i_start,

  input  logic [8:0]         i_seq_len,
  input  logic [7:0]         i_head_dim,
  input  logic [15:0]        i_stride_bytes,
  input  logic [31:0]        i_q_base,
  input  logic [31:0]        i_k_base,
  input  logic [31:0]        i_v_base,
  input  logic [31:0]        i_o_base,

  input  logic signed [15:0] i_score_scale_q1_14,
  input  logic [1:0]         i_round_mode,
  input  logic               i_saturate_en,

  output logic               dma_rd_cmd_valid,
  input  logic               dma_rd_cmd_ready,
  output logic [31:0]        dma_rd_cmd_addr,
  output logic [15:0]        dma_rd_cmd_len,

  input  logic               dma_rd_data_valid,
  output logic               dma_rd_data_ready,
  input  logic [BUS_W-1:0]   dma_rd_data,
  input  logic               dma_rd_data_last,

  output logic               dma_wr_cmd_valid,
  input  logic               dma_wr_cmd_ready,
  output logic [31:0]        dma_wr_cmd_addr,
  output logic [15:0]        dma_wr_cmd_len,

  output logic               dma_wr_data_valid,
  input  logic               dma_wr_data_ready,
  output logic [BUS_W-1:0]   dma_wr_data,
  output logic               dma_wr_data_last,

  output logic               o_busy,
  output logic               o_done,
  output logic [31:0]        o_cycle_count,

  output logic [31:0]        o_perf_rd_cmd,
  output logic [31:0]        o_perf_rd_beat,
  output logic [31:0]        o_perf_wr_cmd,
  output logic [31:0]        o_perf_wr_beat,
  output logic [31:0]        o_perf_compute_cycles,
  output logic [31:0]        o_perf_softmax_updates,

  output logic [4:0]         o_dbg_state,
  output logic [7:0]         o_dbg_qt,
  output logic [7:0]         o_dbg_kt,
  output logic [15:0]        o_dbg_rd_beat_idx,
  output logic [15:0]        o_dbg_wr_beat_idx,
  output logic [7:0]         o_dbg_q00,
  output logic [7:0]         o_dbg_k00,
  output logic [7:0]         o_dbg_v00,
  output logic [7:0]         o_dbg_q_last,
  output logic [7:0]         o_dbg_q31_15,
  output logic [7:0]         o_dbg_q31_31,
  output logic [7:0]         o_dbg_k_last,
  output logic [7:0]         o_dbg_v_last,
  output logic [31:0]        o_dbg_q_sum,
  output logic [31:0]        o_dbg_k_sum,
  output logic [31:0]        o_dbg_v_sum,
  output logic [15:0]        o_dbg_q_load_idx,
  output logic [7:0]         o_dbg_q_load_b0,
  output logic [7:0]         o_dbg_q_load_b15,
  output logic signed [31:0] o_dbg_m0,
  output logic [31:0]        o_dbg_l0,
  output logic signed [63:0] o_dbg_acc00,
  output logic signed [31:0] o_dbg_o00
);
  localparam int FP8_PER_BEAT = BUS_W / 8;
  localparam int I32_PER_BEAT = BUS_W / 32;

  typedef enum logic [4:0] {
    ST_IDLE        = 5'd0,
    ST_LOAD_Q_CMD  = 5'd1,
    ST_LOAD_Q_DATA = 5'd2,
    ST_INIT_CTX    = 5'd3,
    ST_LOAD_K_CMD  = 5'd4,
    ST_LOAD_K_DATA = 5'd5,
    ST_LOAD_V_CMD  = 5'd6,
    ST_LOAD_V_DATA = 5'd7,
    ST_COMPUTE     = 5'd8,
    ST_NEXT_K      = 5'd9,
    ST_NORMALIZE   = 5'd10,
    ST_WRITE_O_CMD = 5'd11,
    ST_WRITE_O_DATA= 5'd12,
    ST_NEXT_Q      = 5'd13,
    ST_DONE        = 5'd14
  } state_t;

  state_t st_r;

  logic [7:0] q_tile [0:TQ-1][0:MAX_D-1];
  logic [7:0] k_tile [0:TK-1][0:MAX_D-1];
  logic [7:0] v_tile [0:TK-1][0:MAX_D-1];

  logic signed [31:0] row_m [0:TQ-1];
  logic [31:0] row_l [0:TQ-1];
  logic signed [63:0] row_acc [0:TQ-1][0:MAX_D-1];
  logic signed [31:0] o_tile [0:TQ-1][0:MAX_D-1];

  logic [7:0] qt_r;
  logic [7:0] kt_r;

  logic [31:0] rd_addr_r;
  logic [15:0] rd_len_r;
  logic [15:0] rd_beat_idx_r;

  logic [31:0] wr_addr_r;
  logic [15:0] wr_len_r;
  logic [15:0] wr_beat_idx_r;

  logic [15:0] q_beats_r;
  logic [15:0] k_beats_r;
  logic [15:0] v_beats_r;
  logic [15:0] o_beats_r;
  logic        rd_data_arm_r;

  logic [31:0] cycle_r;
  logic [31:0] perf_rd_cmd_r;
  logic [31:0] perf_rd_beat_r;
  logic [31:0] perf_wr_cmd_r;
  logic [31:0] perf_wr_beat_r;
  logic [31:0] perf_compute_cycles_r;
  logic [31:0] perf_softmax_updates_r;
  logic signed [63:0] acc_loc_w [0:MAX_D-1];
  logic [31:0] dbg_q_sum_r;
  logic [31:0] dbg_k_sum_r;
  logic [31:0] dbg_v_sum_r;
  logic [15:0] dbg_q_load_idx_r;
  logic [7:0]  dbg_q_load_b0_r;
  logic [7:0]  dbg_q_load_b15_r;

  integer qi;
  integer kj;
  integer d;

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
        if (mag > 32'sd32767) mag = 32'sd32767;
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
    logic signed [31:0] dlt;
    logic [4:0] sh;
    begin
      dlt = delta_q8_11 >>> 8;
      if (dlt >= 0) begin
        exp2_approx_q0_15 = 16'sd32767;
      end else if (dlt <= -32'sd15) begin
        exp2_approx_q0_15 = 16'sd0;
      end else begin
        sh = -dlt;
        exp2_approx_q0_15 = 16'sd32767 >>> sh;
      end
    end
  endfunction

  function automatic [31:0] div_u32(input [63:0] n, input [31:0] d0);
    begin
      if (d0 == 0) div_u32 = 32'd0;
      else div_u32 = n / d0;
    end
  endfunction

  function automatic [15:0] ceil_div_u16(input [31:0] n, input [31:0] d0);
    begin
      ceil_div_u16 = (n + d0 - 1) / d0;
    end
  endfunction

  task automatic issue_rd_cmd(input [31:0] addr, input [15:0] beats_minus1);
    begin
      dma_rd_cmd_addr <= addr;
      dma_rd_cmd_len <= beats_minus1;
      dma_rd_cmd_valid <= 1'b1;
    end
  endtask

  task automatic issue_wr_cmd(input [31:0] addr, input [15:0] beats_minus1);
    begin
      dma_wr_cmd_addr <= addr;
      dma_wr_cmd_len <= beats_minus1;
      dma_wr_cmd_valid <= 1'b1;
    end
  endtask

  task automatic load_fp8_beat_into_tile(
    input logic [BUS_W-1:0] beat,
    input int rows,
    input int cols,
    input int beat_idx,
    inout logic [7:0] tile [0:TQ-1][0:MAX_D-1]
  );
    int flat_base;
    int e;
    int rr;
    int cc;
    begin
      flat_base = beat_idx * FP8_PER_BEAT;
      for (e = 0; e < FP8_PER_BEAT; e++) begin
        rr = (flat_base + e) / cols;
        cc = (flat_base + e) % cols;
        if (rr < rows && cc < cols) begin
          tile[rr][cc] = beat[e*8 +: 8];
        end
      end
    end
  endtask

  task automatic load_fp8_beat_into_kv(
    input logic [BUS_W-1:0] beat,
    input int rows,
    input int cols,
    input int beat_idx,
    inout logic [7:0] tile [0:TK-1][0:MAX_D-1]
  );
    int flat_base;
    int e;
    int rr;
    int cc;
    begin
      flat_base = beat_idx * FP8_PER_BEAT;
      for (e = 0; e < FP8_PER_BEAT; e++) begin
        rr = (flat_base + e) / cols;
        cc = (flat_base + e) % cols;
        if (rr < rows && cc < cols) begin
          tile[rr][cc] = beat[e*8 +: 8];
        end
      end
    end
  endtask

  function automatic [BUS_W-1:0] pack_o_beat(input int rows, input int cols, input int beat_idx);
    logic [BUS_W-1:0] outv;
    int flat_base;
    int e;
    int rr;
    int cc;
    begin
      outv = '0;
      flat_base = beat_idx * I32_PER_BEAT;
      for (e = 0; e < I32_PER_BEAT; e++) begin
        rr = (flat_base + e) / cols;
        cc = (flat_base + e) % cols;
        if (rr < rows && cc < cols) begin
          outv[e*32 +: 32] = o_tile[rr][cc];
        end
      end
      pack_o_beat = outv;
    end
  endfunction

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      st_r <= ST_IDLE;
      qt_r <= 0;
      kt_r <= 0;
      rd_addr_r <= 0;
      rd_len_r <= 0;
      rd_beat_idx_r <= 0;
      wr_addr_r <= 0;
      wr_len_r <= 0;
      wr_beat_idx_r <= 0;
      q_beats_r <= 0;
      k_beats_r <= 0;
      v_beats_r <= 0;
      o_beats_r <= 0;
      cycle_r <= 0;
      perf_rd_cmd_r <= 0;
      perf_rd_beat_r <= 0;
      perf_wr_cmd_r <= 0;
      perf_wr_beat_r <= 0;
      perf_compute_cycles_r <= 0;
      perf_softmax_updates_r <= 0;
      dbg_q_sum_r <= 0;
      dbg_k_sum_r <= 0;
      dbg_v_sum_r <= 0;
      dbg_q_load_idx_r <= 0;
      dbg_q_load_b0_r <= 0;
      dbg_q_load_b15_r <= 0;
      dma_rd_cmd_valid <= 0;
      dma_rd_cmd_addr <= 0;
      dma_rd_cmd_len <= 0;
      dma_rd_data_ready <= 0;
      dma_wr_cmd_valid <= 0;
      dma_wr_cmd_addr <= 0;
      dma_wr_cmd_len <= 0;
      dma_wr_data_valid <= 0;
      dma_wr_data <= 0;
      dma_wr_data_last <= 0;
      o_busy <= 0;
      o_done <= 0;
      rd_data_arm_r <= 1'b0;
      for (qi = 0; qi < TQ; qi++) begin
        row_m[qi] <= -32'sd2147483648;
        row_l[qi] <= 32'd0;
        for (d = 0; d < MAX_D; d++) begin
          row_acc[qi][d] <= 64'sd0;
          o_tile[qi][d] <= 32'sd0;
          q_tile[qi][d] <= 8'd0;
        end
      end
      for (kj = 0; kj < TK; kj++) begin
        for (d = 0; d < MAX_D; d++) begin
          k_tile[kj][d] <= 8'd0;
          v_tile[kj][d] <= 8'd0;
        end
      end
    end else begin
      o_done <= 1'b0;
      dma_rd_data_ready <= 1'b0;
      dma_wr_data_last <= 1'b0;
      if (st_r != ST_IDLE) cycle_r <= cycle_r + 1;

      case (st_r)
        ST_IDLE: begin
          o_busy <= 1'b0;
          dma_rd_cmd_valid <= 1'b0;
          dma_wr_cmd_valid <= 1'b0;
          dma_wr_data_valid <= 1'b0;
          if (i_start) begin
            o_busy <= 1'b1;
            qt_r <= 0;
            kt_r <= 0;
            q_beats_r <= ceil_div_u16(TQ * i_head_dim, FP8_PER_BEAT);
            k_beats_r <= ceil_div_u16(TK * i_head_dim, FP8_PER_BEAT);
            v_beats_r <= ceil_div_u16(TK * i_head_dim, FP8_PER_BEAT);
            o_beats_r <= ceil_div_u16(TQ * i_head_dim, I32_PER_BEAT);
            perf_rd_cmd_r <= 0;
            perf_rd_beat_r <= 0;
            perf_wr_cmd_r <= 0;
            perf_wr_beat_r <= 0;
            perf_compute_cycles_r <= 0;
            perf_softmax_updates_r <= 0;
            st_r <= ST_LOAD_Q_CMD;
          end
        end

        ST_LOAD_Q_CMD: begin
          dbg_q_sum_r <= 0;
          rd_addr_r <= i_q_base + qt_r * TQ * i_stride_bytes;
          rd_len_r <= q_beats_r - 1;
          issue_rd_cmd(i_q_base + qt_r * TQ * i_stride_bytes, q_beats_r - 1);
          if (dma_rd_cmd_valid && dma_rd_cmd_ready) begin
            dma_rd_cmd_valid <= 1'b0;
            perf_rd_cmd_r <= perf_rd_cmd_r + 1;
            rd_beat_idx_r <= 0;
            rd_data_arm_r <= 1'b1;
            st_r <= ST_LOAD_Q_DATA;
          end
        end

        ST_LOAD_Q_DATA: begin
          int flat_base;
          int e;
          int rr;
          int cc;
          logic [31:0] beat_sum;
          dma_rd_data_ready <= 1'b1;
          if (rd_data_arm_r) begin
            rd_data_arm_r <= 1'b0;
          end else if (dma_rd_data_valid && dma_rd_data_ready) begin
            flat_base = rd_beat_idx_r * FP8_PER_BEAT;
            beat_sum = 32'd0;
            for (e = 0; e < FP8_PER_BEAT; e++) begin
              rr = (flat_base + e) / i_head_dim;
              cc = (flat_base + e) % i_head_dim;
              if (rr < TQ && cc < i_head_dim)
                begin
                  q_tile[rr][cc] = dma_rd_data[e*8 +: 8];
                  beat_sum = beat_sum + dma_rd_data[e*8 +: 8];
                end
            end
            dbg_q_sum_r <= dbg_q_sum_r + beat_sum;
            dbg_q_load_idx_r <= rd_beat_idx_r;
            dbg_q_load_b0_r <= dma_rd_data[7:0];
            dbg_q_load_b15_r <= dma_rd_data[127:120];
            rd_beat_idx_r <= rd_beat_idx_r + 1;
            perf_rd_beat_r <= perf_rd_beat_r + 1;
            if (rd_beat_idx_r + 1 >= q_beats_r || dma_rd_data_last) begin
              st_r <= ST_INIT_CTX;
            end
          end
        end

        ST_INIT_CTX: begin
          for (qi = 0; qi < TQ; qi++) begin
            row_m[qi] <= -32'sd2147483648;
            row_l[qi] <= 32'd0;
            for (d = 0; d < i_head_dim; d++) begin
              row_acc[qi][d] <= 64'sd0;
              o_tile[qi][d] <= 32'sd0;
            end
          end
          kt_r <= 0;
          st_r <= ST_LOAD_K_CMD;
        end

        ST_LOAD_K_CMD: begin
          dbg_k_sum_r <= 0;
          rd_addr_r <= i_k_base + kt_r * TK * i_stride_bytes;
          rd_len_r <= k_beats_r - 1;
          issue_rd_cmd(i_k_base + kt_r * TK * i_stride_bytes, k_beats_r - 1);
          if (dma_rd_cmd_valid && dma_rd_cmd_ready) begin
            dma_rd_cmd_valid <= 1'b0;
            perf_rd_cmd_r <= perf_rd_cmd_r + 1;
            rd_beat_idx_r <= 0;
            rd_data_arm_r <= 1'b1;
            st_r <= ST_LOAD_K_DATA;
          end
        end

        ST_LOAD_K_DATA: begin
          int flat_base;
          int e;
          int rr;
          int cc;
          logic [31:0] beat_sum;
          dma_rd_data_ready <= 1'b1;
          if (rd_data_arm_r) begin
            rd_data_arm_r <= 1'b0;
          end else if (dma_rd_data_valid && dma_rd_data_ready) begin
            flat_base = rd_beat_idx_r * FP8_PER_BEAT;
            beat_sum = 32'd0;
            for (e = 0; e < FP8_PER_BEAT; e++) begin
              rr = (flat_base + e) / i_head_dim;
              cc = (flat_base + e) % i_head_dim;
              if (rr < TK && cc < i_head_dim)
                begin
                  k_tile[rr][cc] = dma_rd_data[e*8 +: 8];
                  beat_sum = beat_sum + dma_rd_data[e*8 +: 8];
                end
            end
            dbg_k_sum_r <= dbg_k_sum_r + beat_sum;
            rd_beat_idx_r <= rd_beat_idx_r + 1;
            perf_rd_beat_r <= perf_rd_beat_r + 1;
            if (rd_beat_idx_r + 1 >= k_beats_r || dma_rd_data_last) begin
              st_r <= ST_LOAD_V_CMD;
            end
          end
        end

        ST_LOAD_V_CMD: begin
          dbg_v_sum_r <= 0;
          rd_addr_r <= i_v_base + kt_r * TK * i_stride_bytes;
          rd_len_r <= v_beats_r - 1;
          issue_rd_cmd(i_v_base + kt_r * TK * i_stride_bytes, v_beats_r - 1);
          if (dma_rd_cmd_valid && dma_rd_cmd_ready) begin
            dma_rd_cmd_valid <= 1'b0;
            perf_rd_cmd_r <= perf_rd_cmd_r + 1;
            rd_beat_idx_r <= 0;
            rd_data_arm_r <= 1'b1;
            st_r <= ST_LOAD_V_DATA;
          end
        end

        ST_LOAD_V_DATA: begin
          int flat_base;
          int e;
          int rr;
          int cc;
          logic [31:0] beat_sum;
          dma_rd_data_ready <= 1'b1;
          if (rd_data_arm_r) begin
            rd_data_arm_r <= 1'b0;
          end else if (dma_rd_data_valid && dma_rd_data_ready) begin
            flat_base = rd_beat_idx_r * FP8_PER_BEAT;
            beat_sum = 32'd0;
            for (e = 0; e < FP8_PER_BEAT; e++) begin
              rr = (flat_base + e) / i_head_dim;
              cc = (flat_base + e) % i_head_dim;
              if (rr < TK && cc < i_head_dim)
                begin
                  v_tile[rr][cc] = dma_rd_data[e*8 +: 8];
                  beat_sum = beat_sum + dma_rd_data[e*8 +: 8];
                end
            end
            dbg_v_sum_r <= dbg_v_sum_r + beat_sum;
            rd_beat_idx_r <= rd_beat_idx_r + 1;
            perf_rd_beat_r <= perf_rd_beat_r + 1;
            if (rd_beat_idx_r + 1 >= v_beats_r || dma_rd_data_last) begin
              st_r <= ST_COMPUTE;
            end
          end
        end

        ST_COMPUTE: begin
          logic signed [63:0] dot_tmp;
          logic signed [31:0] qv_i;
          logic signed [31:0] kv_i;
          logic signed [63:0] qk_prod;
          logic signed [63:0] score_tmp;
          logic signed [31:0] score_i;
          logic signed [31:0] m_loc;
          logic signed [31:0] m_new;
          logic signed [15:0] exp_old;
          logic signed [15:0] exp_new;
          logic [31:0] l_loc;
          logic signed [63:0] l_mul;
          logic [31:0] l_scaled;
          logic [31:0] l_new;
          logic signed [63:0] acc_old;
          logic signed [63:0] acc_mul;
          logic signed [63:0] acc_scaled;
          logic signed [31:0] vv_i;
          logic signed [63:0] v_term;

          perf_compute_cycles_r <= perf_compute_cycles_r + 1;
          for (qi = 0; qi < TQ; qi++) begin
            m_loc = row_m[qi];
            l_loc = row_l[qi];
            for (d = 0; d < i_head_dim; d++) begin
              acc_loc_w[d] = row_acc[qi][d];
            end

            for (kj = 0; kj < TK; kj++) begin
              dot_tmp = 64'sd0;
              for (d = 0; d < i_head_dim; d++) begin
                qv_i = $signed(fp8_e4m3_to_q4_11(q_tile[qi][d]));
                kv_i = $signed(fp8_e4m3_to_q4_11(k_tile[kj][d]));
                qk_prod = qv_i * kv_i;
                dot_tmp = dot_tmp + qk_prod;
              end

              score_tmp = round_shift_right_64(dot_tmp, 11, i_round_mode);
              score_tmp = (score_tmp * $signed(i_score_scale_q1_14)) >>> 14;
              if (i_saturate_en) begin
                if (score_tmp > 64'sd2147483647) score_i = 32'sd2147483647;
                else if (score_tmp < -64'sd2147483648) score_i = -32'sd2147483648;
                else score_i = score_tmp[31:0];
              end else begin
                score_i = score_tmp[31:0];
              end

              m_new = (score_i > m_loc) ? score_i : m_loc;
              if (l_loc == 0) exp_old = 16'sd0;
              else exp_old = exp2_approx_q0_15(m_loc - m_new);
              exp_new = exp2_approx_q0_15(score_i - m_new);

              l_mul = $signed({1'b0, l_loc}) * $signed(exp_old);
              l_scaled = l_mul >>> 15;
              l_new = l_scaled + ({16'd0, exp_new} << 1);

              m_loc = m_new;
              l_loc = l_new;
              perf_softmax_updates_r <= perf_softmax_updates_r + 1;

              for (d = 0; d < i_head_dim; d++) begin
                acc_old = acc_loc_w[d];
                acc_mul = acc_old * $signed(exp_old);
                acc_scaled = acc_mul >>> 15;
                vv_i = $signed(fp8_e4m3_to_q4_11(v_tile[kj][d]));
                v_term = vv_i * $signed(exp_new);
                acc_loc_w[d] = acc_scaled + v_term;
              end
            end

            row_m[qi] <= m_loc;
            row_l[qi] <= l_loc;
            for (d = 0; d < i_head_dim; d++) begin
              row_acc[qi][d] <= acc_loc_w[d];
            end
          end
          st_r <= ST_NEXT_K;
        end

        ST_NEXT_K: begin
          if (kt_r + 1 >= (i_seq_len / TK)) begin
            st_r <= ST_NORMALIZE;
          end else begin
            kt_r <= kt_r + 1;
            st_r <= ST_LOAD_K_CMD;
          end
        end

        ST_NORMALIZE: begin
          logic [31:0] den;
          logic signed [63:0] num;
          logic signed [63:0] divv;
          for (qi = 0; qi < TQ; qi++) begin
            den = row_l[qi];
            for (d = 0; d < i_head_dim; d++) begin
              num = row_acc[qi][d];
              if (den == 0) divv = 64'sd0;
              else divv = num / $signed({1'b0, den});
              o_tile[qi][d] <= divv[31:0];
            end
          end
          st_r <= ST_WRITE_O_CMD;
        end

        ST_WRITE_O_CMD: begin
          wr_addr_r <= i_o_base + qt_r * TQ * (i_head_dim * 4);
          wr_len_r <= o_beats_r - 1;
          issue_wr_cmd(i_o_base + qt_r * TQ * (i_head_dim * 4), o_beats_r - 1);
          if (dma_wr_cmd_valid && dma_wr_cmd_ready) begin
            dma_wr_cmd_valid <= 1'b0;
            perf_wr_cmd_r <= perf_wr_cmd_r + 1;
            wr_beat_idx_r <= 0;
            st_r <= ST_WRITE_O_DATA;
          end
        end

        ST_WRITE_O_DATA: begin
          if (!dma_wr_data_valid) begin
            dma_wr_data_valid <= 1'b1;
            dma_wr_data <= pack_o_beat(TQ, i_head_dim, wr_beat_idx_r);
            dma_wr_data_last <= (wr_beat_idx_r + 1 >= o_beats_r);
          end else if (dma_wr_data_ready) begin
            perf_wr_beat_r <= perf_wr_beat_r + 1;
            if (wr_beat_idx_r + 1 >= o_beats_r) begin
              dma_wr_data_valid <= 1'b0;
              st_r <= ST_NEXT_Q;
            end else begin
              wr_beat_idx_r <= wr_beat_idx_r + 1;
              dma_wr_data <= pack_o_beat(TQ, i_head_dim, wr_beat_idx_r + 1);
              dma_wr_data_last <= (wr_beat_idx_r + 2 >= o_beats_r);
            end
          end
        end

        ST_NEXT_Q: begin
          if (qt_r + 1 >= (i_seq_len / TQ)) begin
            st_r <= ST_DONE;
          end else begin
            qt_r <= qt_r + 1;
            st_r <= ST_LOAD_Q_CMD;
          end
        end

        ST_DONE: begin
          o_busy <= 1'b0;
          o_done <= 1'b1;
          if (!i_start) begin
            st_r <= ST_IDLE;
          end
        end

        default: begin
          st_r <= ST_IDLE;
        end
      endcase
    end
  end

  assign o_cycle_count = cycle_r;
  assign o_perf_rd_cmd = perf_rd_cmd_r;
  assign o_perf_rd_beat = perf_rd_beat_r;
  assign o_perf_wr_cmd = perf_wr_cmd_r;
  assign o_perf_wr_beat = perf_wr_beat_r;
  assign o_perf_compute_cycles = perf_compute_cycles_r;
  assign o_perf_softmax_updates = perf_softmax_updates_r;
  assign o_dbg_state = st_r;
  assign o_dbg_qt = qt_r;
  assign o_dbg_kt = kt_r;
  assign o_dbg_rd_beat_idx = rd_beat_idx_r;
  assign o_dbg_wr_beat_idx = wr_beat_idx_r;
  assign o_dbg_q00 = q_tile[0][0];
  assign o_dbg_k00 = k_tile[0][0];
  assign o_dbg_v00 = v_tile[0][0];
  assign o_dbg_q_last = q_tile[TQ-1][31];
  assign o_dbg_q31_15 = q_tile[TQ-1][15];
  assign o_dbg_q31_31 = q_tile[TQ-1][31];
  assign o_dbg_k_last = k_tile[TK-1][31];
  assign o_dbg_v_last = v_tile[TK-1][31];
  assign o_dbg_q_sum = dbg_q_sum_r;
  assign o_dbg_k_sum = dbg_k_sum_r;
  assign o_dbg_v_sum = dbg_v_sum_r;
  assign o_dbg_q_load_idx = dbg_q_load_idx_r;
  assign o_dbg_q_load_b0 = dbg_q_load_b0_r;
  assign o_dbg_q_load_b15 = dbg_q_load_b15_r;
  assign o_dbg_m0 = row_m[0];
  assign o_dbg_l0 = row_l[0];
  assign o_dbg_acc00 = row_acc[0][0];
  assign o_dbg_o00 = o_tile[0][0];

endmodule
