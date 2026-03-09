module fa_perf_counters (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        i_run_start,
  input  logic        i_soft_reset,

  input  logic        i_ms_load_q,
  input  logic        i_ms_init_context,
  input  logic        i_ms_load_k,
  input  logic        i_ms_load_v,
  input  logic        i_ms_compute,
  input  logic        i_ms_normalize,
  input  logic        i_ms_write_o,
  input  logic        i_ms_next_q,

  input  logic        i_cs_dp_run,
  input  logic        i_cs_score_done,
  input  logic        i_cs_softmax_prep,
  input  logic        i_comp_launch,
  input  logic [1:0]  i_active_rows,

  input  logic        i_norm_recip_req,
  input  logic        i_norm_recip_rsp,

  input  logic        i_dma_rd_cmd_fire,
  input  logic        i_dma_rd_beat_fire,
  input  logic        i_dma_wr_cmd_fire,
  input  logic        i_dma_wr_beat_fire,

  output logic [31:0] o_run_count,
  output logic [31:0] o_busy_cycles,
  output logic [31:0] o_dma_rd_cmd_count,
  output logic [31:0] o_dma_rd_beat_count,
  output logic [31:0] o_dma_wr_cmd_count,
  output logic [31:0] o_dma_wr_beat_count,
  output logic [31:0] o_comp_launch_count,
  output logic [31:0] o_exp_eval_count,
  output logic [31:0] o_mul_eval_count,
  output logic [31:0] o_recip_req_count,
  output logic [31:0] o_recip_rsp_count,
  output logic [31:0] o_ms_load_q_cycles,
  output logic [31:0] o_ms_init_context_cycles,
  output logic [31:0] o_ms_load_k_cycles,
  output logic [31:0] o_ms_load_v_cycles,
  output logic [31:0] o_ms_compute_cycles,
  output logic [31:0] o_ms_normalize_cycles,
  output logic [31:0] o_ms_write_o_cycles,
  output logic [31:0] o_ms_next_q_cycles,
  output logic [31:0] o_cs_dp_run_cycles,
  output logic [31:0] o_cs_score_done_cycles,
  output logic [31:0] o_cs_softmax_prep_cycles
);
  logic perf_active;
  logic [31:0] exp_inc;
  logic [31:0] mul_inc;

  always_comb begin
    perf_active = i_ms_load_q || i_ms_init_context || i_ms_load_k || i_ms_load_v ||
                  i_ms_compute || i_ms_normalize || i_ms_write_o || i_ms_next_q;

    unique case (i_active_rows)
      2'd2: begin
        exp_inc = 32'd4;
        mul_inc = 32'd2;
      end
      2'd1: begin
        exp_inc = 32'd2;
        mul_inc = 32'd1;
      end
      default: begin
        exp_inc = 32'd0;
        mul_inc = 32'd0;
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_run_count <= 32'd0;
      o_busy_cycles <= 32'd0;
      o_dma_rd_cmd_count <= 32'd0;
      o_dma_rd_beat_count <= 32'd0;
      o_dma_wr_cmd_count <= 32'd0;
      o_dma_wr_beat_count <= 32'd0;
      o_comp_launch_count <= 32'd0;
      o_exp_eval_count <= 32'd0;
      o_mul_eval_count <= 32'd0;
      o_recip_req_count <= 32'd0;
      o_recip_rsp_count <= 32'd0;
      o_ms_load_q_cycles <= 32'd0;
      o_ms_init_context_cycles <= 32'd0;
      o_ms_load_k_cycles <= 32'd0;
      o_ms_load_v_cycles <= 32'd0;
      o_ms_compute_cycles <= 32'd0;
      o_ms_normalize_cycles <= 32'd0;
      o_ms_write_o_cycles <= 32'd0;
      o_ms_next_q_cycles <= 32'd0;
      o_cs_dp_run_cycles <= 32'd0;
      o_cs_score_done_cycles <= 32'd0;
      o_cs_softmax_prep_cycles <= 32'd0;
    end else if (i_soft_reset) begin
      o_busy_cycles <= 32'd0;
      o_dma_rd_cmd_count <= 32'd0;
      o_dma_rd_beat_count <= 32'd0;
      o_dma_wr_cmd_count <= 32'd0;
      o_dma_wr_beat_count <= 32'd0;
      o_comp_launch_count <= 32'd0;
      o_exp_eval_count <= 32'd0;
      o_mul_eval_count <= 32'd0;
      o_recip_req_count <= 32'd0;
      o_recip_rsp_count <= 32'd0;
      o_ms_load_q_cycles <= 32'd0;
      o_ms_init_context_cycles <= 32'd0;
      o_ms_load_k_cycles <= 32'd0;
      o_ms_load_v_cycles <= 32'd0;
      o_ms_compute_cycles <= 32'd0;
      o_ms_normalize_cycles <= 32'd0;
      o_ms_write_o_cycles <= 32'd0;
      o_ms_next_q_cycles <= 32'd0;
      o_cs_dp_run_cycles <= 32'd0;
      o_cs_score_done_cycles <= 32'd0;
      o_cs_softmax_prep_cycles <= 32'd0;
    end else begin
      if (i_run_start) begin
        o_run_count <= o_run_count + 32'd1;
        o_busy_cycles <= 32'd0;
        o_dma_rd_cmd_count <= 32'd0;
        o_dma_rd_beat_count <= 32'd0;
        o_dma_wr_cmd_count <= 32'd0;
        o_dma_wr_beat_count <= 32'd0;
        o_comp_launch_count <= 32'd0;
        o_exp_eval_count <= 32'd0;
        o_mul_eval_count <= 32'd0;
        o_recip_req_count <= 32'd0;
        o_recip_rsp_count <= 32'd0;
        o_ms_load_q_cycles <= 32'd0;
        o_ms_init_context_cycles <= 32'd0;
        o_ms_load_k_cycles <= 32'd0;
        o_ms_load_v_cycles <= 32'd0;
        o_ms_compute_cycles <= 32'd0;
        o_ms_normalize_cycles <= 32'd0;
        o_ms_write_o_cycles <= 32'd0;
        o_ms_next_q_cycles <= 32'd0;
        o_cs_dp_run_cycles <= 32'd0;
        o_cs_score_done_cycles <= 32'd0;
        o_cs_softmax_prep_cycles <= 32'd0;
      end else begin
        if (perf_active) begin
          o_busy_cycles <= o_busy_cycles + 32'd1;
        end
        if (i_ms_load_q) begin
          o_ms_load_q_cycles <= o_ms_load_q_cycles + 32'd1;
        end
        if (i_ms_init_context) begin
          o_ms_init_context_cycles <= o_ms_init_context_cycles + 32'd1;
        end
        if (i_ms_load_k) begin
          o_ms_load_k_cycles <= o_ms_load_k_cycles + 32'd1;
        end
        if (i_ms_load_v) begin
          o_ms_load_v_cycles <= o_ms_load_v_cycles + 32'd1;
        end
        if (i_ms_compute) begin
          o_ms_compute_cycles <= o_ms_compute_cycles + 32'd1;
        end
        if (i_ms_normalize) begin
          o_ms_normalize_cycles <= o_ms_normalize_cycles + 32'd1;
        end
        if (i_ms_write_o) begin
          o_ms_write_o_cycles <= o_ms_write_o_cycles + 32'd1;
        end
        if (i_ms_next_q) begin
          o_ms_next_q_cycles <= o_ms_next_q_cycles + 32'd1;
        end
        if (i_cs_dp_run) begin
          o_cs_dp_run_cycles <= o_cs_dp_run_cycles + 32'd1;
        end
        if (i_cs_score_done) begin
          o_cs_score_done_cycles <= o_cs_score_done_cycles + 32'd1;
          o_mul_eval_count <= o_mul_eval_count + mul_inc;
        end
        if (i_cs_softmax_prep) begin
          o_cs_softmax_prep_cycles <= o_cs_softmax_prep_cycles + 32'd1;
          o_exp_eval_count <= o_exp_eval_count + exp_inc;
        end
        if (i_comp_launch) begin
          o_comp_launch_count <= o_comp_launch_count + 32'd1;
        end
        if (i_norm_recip_req) begin
          o_recip_req_count <= o_recip_req_count + 32'd1;
        end
        if (i_norm_recip_rsp) begin
          o_recip_rsp_count <= o_recip_rsp_count + 32'd1;
        end
        if (i_dma_rd_cmd_fire) begin
          o_dma_rd_cmd_count <= o_dma_rd_cmd_count + 32'd1;
        end
        if (i_dma_rd_beat_fire) begin
          o_dma_rd_beat_count <= o_dma_rd_beat_count + 32'd1;
        end
        if (i_dma_wr_cmd_fire) begin
          o_dma_wr_cmd_count <= o_dma_wr_cmd_count + 32'd1;
        end
        if (i_dma_wr_beat_fire) begin
          o_dma_wr_beat_count <= o_dma_wr_beat_count + 32'd1;
        end
      end
    end
  end
endmodule
