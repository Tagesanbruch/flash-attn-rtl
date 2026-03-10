class fa_reg32 extends uvm_reg;
  `uvm_object_utils(fa_reg32)

  uvm_reg_field value;
  string        access;
  uvm_reg_data_t reset_value;

  function new(string name = "fa_reg32", string access = "RW", uvm_reg_data_t reset_value = '0);
    super.new(name, 32, UVM_NO_COVERAGE);
    this.access = access;
    this.reset_value = reset_value;
  endfunction

  virtual function void build();
    value = uvm_reg_field::type_id::create("value");
    value.configure(this, 32, 0, access, 0, reset_value, 1, 1, 0);
  endfunction
endclass

class fa_attention_reg_block extends uvm_reg_block;
  `uvm_object_utils(fa_attention_reg_block)

  rand fa_reg32 ctrl;
  rand fa_reg32 status;
  rand fa_reg32 cfg;
  rand fa_reg32 q_base_l;
  rand fa_reg32 q_base_h;
  rand fa_reg32 k_base_l;
  rand fa_reg32 k_base_h;
  rand fa_reg32 v_base_l;
  rand fa_reg32 v_base_h;
  rand fa_reg32 o_base_l;
  rand fa_reg32 o_base_h;
  rand fa_reg32 stride_bytes;
  rand fa_reg32 neg_large;
  rand fa_reg32 scale;
  rand fa_reg32 cycles;
  rand fa_reg32 perf_run_count;
  rand fa_reg32 perf_busy_cycles;
  rand fa_reg32 perf_dma_rd_cmd_count;
  rand fa_reg32 perf_dma_rd_beat_count;
  rand fa_reg32 perf_dma_wr_cmd_count;
  rand fa_reg32 perf_dma_wr_beat_count;
  rand fa_reg32 perf_comp_launch_count;
  rand fa_reg32 perf_exp_eval_count;
  rand fa_reg32 perf_mul_eval_count;
  rand fa_reg32 perf_recip_req_count;
  rand fa_reg32 perf_recip_rsp_count;
  rand fa_reg32 perf_ms_load_q_cycles;
  rand fa_reg32 perf_ms_init_context_cycles;
  rand fa_reg32 perf_ms_load_k_cycles;
  rand fa_reg32 perf_ms_load_v_cycles;
  rand fa_reg32 perf_ms_compute_cycles;
  rand fa_reg32 perf_ms_normalize_cycles;
  rand fa_reg32 perf_ms_write_o_cycles;
  rand fa_reg32 perf_ms_next_q_cycles;
  rand fa_reg32 perf_cs_dp_run_cycles;
  rand fa_reg32 perf_cs_score_done_cycles;
  rand fa_reg32 perf_cs_softmax_prep_cycles;

  function new(string name = "fa_attention_reg_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  protected function fa_reg32 create_reg(string name, string access, uvm_reg_data_t reset_value);
    fa_reg32 reg_h;
    reg_h = new(name, access, reset_value);
    reg_h.configure(this, null, "");
    reg_h.build();
    return reg_h;
  endfunction

  virtual function void build();
    default_map = create_map("default_map", 0, 4, UVM_LITTLE_ENDIAN, 1);

    ctrl                        = create_reg("ctrl", "RW", 32'h0000_0000);
    status                      = create_reg("status", "RO", 32'h0000_0000);
    cfg                         = create_reg("cfg", "RW", 32'h0000_0000);
    q_base_l                    = create_reg("q_base_l", "RW", 32'h0000_0000);
    q_base_h                    = create_reg("q_base_h", "RW", 32'h0000_0000);
    k_base_l                    = create_reg("k_base_l", "RW", 32'h0000_0000);
    k_base_h                    = create_reg("k_base_h", "RW", 32'h0000_0000);
    v_base_l                    = create_reg("v_base_l", "RW", 32'h0000_0000);
    v_base_h                    = create_reg("v_base_h", "RW", 32'h0000_0000);
    o_base_l                    = create_reg("o_base_l", "RW", 32'h0000_0000);
    o_base_h                    = create_reg("o_base_h", "RW", 32'h0000_0000);
    stride_bytes                = create_reg("stride_bytes", "RW", 32'h0000_0080);
    neg_large                   = create_reg("neg_large", "RW", 32'hffff_8000);
    scale                       = create_reg("scale", "RW", 32'h0000_0020);
    cycles                      = create_reg("cycles", "RO", 32'h0000_0000);
    perf_run_count              = create_reg("perf_run_count", "RO", 32'h0000_0000);
    perf_busy_cycles            = create_reg("perf_busy_cycles", "RO", 32'h0000_0000);
    perf_dma_rd_cmd_count       = create_reg("perf_dma_rd_cmd_count", "RO", 32'h0000_0000);
    perf_dma_rd_beat_count      = create_reg("perf_dma_rd_beat_count", "RO", 32'h0000_0000);
    perf_dma_wr_cmd_count       = create_reg("perf_dma_wr_cmd_count", "RO", 32'h0000_0000);
    perf_dma_wr_beat_count      = create_reg("perf_dma_wr_beat_count", "RO", 32'h0000_0000);
    perf_comp_launch_count      = create_reg("perf_comp_launch_count", "RO", 32'h0000_0000);
    perf_exp_eval_count         = create_reg("perf_exp_eval_count", "RO", 32'h0000_0000);
    perf_mul_eval_count         = create_reg("perf_mul_eval_count", "RO", 32'h0000_0000);
    perf_recip_req_count        = create_reg("perf_recip_req_count", "RO", 32'h0000_0000);
    perf_recip_rsp_count        = create_reg("perf_recip_rsp_count", "RO", 32'h0000_0000);
    perf_ms_load_q_cycles       = create_reg("perf_ms_load_q_cycles", "RO", 32'h0000_0000);
    perf_ms_init_context_cycles = create_reg("perf_ms_init_context_cycles", "RO", 32'h0000_0000);
    perf_ms_load_k_cycles       = create_reg("perf_ms_load_k_cycles", "RO", 32'h0000_0000);
    perf_ms_load_v_cycles       = create_reg("perf_ms_load_v_cycles", "RO", 32'h0000_0000);
    perf_ms_compute_cycles      = create_reg("perf_ms_compute_cycles", "RO", 32'h0000_0000);
    perf_ms_normalize_cycles    = create_reg("perf_ms_normalize_cycles", "RO", 32'h0000_0000);
    perf_ms_write_o_cycles      = create_reg("perf_ms_write_o_cycles", "RO", 32'h0000_0000);
    perf_ms_next_q_cycles       = create_reg("perf_ms_next_q_cycles", "RO", 32'h0000_0000);
    perf_cs_dp_run_cycles       = create_reg("perf_cs_dp_run_cycles", "RO", 32'h0000_0000);
    perf_cs_score_done_cycles   = create_reg("perf_cs_score_done_cycles", "RO", 32'h0000_0000);
    perf_cs_softmax_prep_cycles = create_reg("perf_cs_softmax_prep_cycles", "RO", 32'h0000_0000);

    default_map.add_reg(ctrl,                        FA_REG_CTRL,                        "RW");
    default_map.add_reg(status,                      FA_REG_STATUS,                      "RO");
    default_map.add_reg(cfg,                         FA_REG_CFG,                         "RW");
    default_map.add_reg(q_base_l,                    FA_REG_Q_BASE_L,                    "RW");
    default_map.add_reg(q_base_h,                    FA_REG_Q_BASE_H,                    "RW");
    default_map.add_reg(k_base_l,                    FA_REG_K_BASE_L,                    "RW");
    default_map.add_reg(k_base_h,                    FA_REG_K_BASE_H,                    "RW");
    default_map.add_reg(v_base_l,                    FA_REG_V_BASE_L,                    "RW");
    default_map.add_reg(v_base_h,                    FA_REG_V_BASE_H,                    "RW");
    default_map.add_reg(o_base_l,                    FA_REG_O_BASE_L,                    "RW");
    default_map.add_reg(o_base_h,                    FA_REG_O_BASE_H,                    "RW");
    default_map.add_reg(stride_bytes,                FA_REG_STRIDE_BYTES,                "RW");
    default_map.add_reg(neg_large,                   FA_REG_NEG_LARGE,                   "RW");
    default_map.add_reg(scale,                       FA_REG_SCALE,                       "RW");
    default_map.add_reg(cycles,                      FA_REG_CYCLES,                      "RO");
    default_map.add_reg(perf_run_count,              FA_REG_PERF_RUN_COUNT,              "RO");
    default_map.add_reg(perf_busy_cycles,            FA_REG_PERF_BUSY_CYCLES,            "RO");
    default_map.add_reg(perf_dma_rd_cmd_count,       FA_REG_PERF_DMA_RD_CMD_COUNT,       "RO");
    default_map.add_reg(perf_dma_rd_beat_count,      FA_REG_PERF_DMA_RD_BEAT_COUNT,      "RO");
    default_map.add_reg(perf_dma_wr_cmd_count,       FA_REG_PERF_DMA_WR_CMD_COUNT,       "RO");
    default_map.add_reg(perf_dma_wr_beat_count,      FA_REG_PERF_DMA_WR_BEAT_COUNT,      "RO");
    default_map.add_reg(perf_comp_launch_count,      FA_REG_PERF_COMP_LAUNCH_COUNT,      "RO");
    default_map.add_reg(perf_exp_eval_count,         FA_REG_PERF_EXP_EVAL_COUNT,         "RO");
    default_map.add_reg(perf_mul_eval_count,         FA_REG_PERF_MUL_EVAL_COUNT,         "RO");
    default_map.add_reg(perf_recip_req_count,        FA_REG_PERF_RECIP_REQ_COUNT,        "RO");
    default_map.add_reg(perf_recip_rsp_count,        FA_REG_PERF_RECIP_RSP_COUNT,        "RO");
    default_map.add_reg(perf_ms_load_q_cycles,       FA_REG_PERF_MS_LOAD_Q_CYCLES,       "RO");
    default_map.add_reg(perf_ms_init_context_cycles, FA_REG_PERF_MS_INIT_CONTEXT_CYCLES, "RO");
    default_map.add_reg(perf_ms_load_k_cycles,       FA_REG_PERF_MS_LOAD_K_CYCLES,       "RO");
    default_map.add_reg(perf_ms_load_v_cycles,       FA_REG_PERF_MS_LOAD_V_CYCLES,       "RO");
    default_map.add_reg(perf_ms_compute_cycles,      FA_REG_PERF_MS_COMPUTE_CYCLES,      "RO");
    default_map.add_reg(perf_ms_normalize_cycles,    FA_REG_PERF_MS_NORMALIZE_CYCLES,    "RO");
    default_map.add_reg(perf_ms_write_o_cycles,      FA_REG_PERF_MS_WRITE_O_CYCLES,      "RO");
    default_map.add_reg(perf_ms_next_q_cycles,       FA_REG_PERF_MS_NEXT_Q_CYCLES,       "RO");
    default_map.add_reg(perf_cs_dp_run_cycles,       FA_REG_PERF_CS_DP_RUN_CYCLES,       "RO");
    default_map.add_reg(perf_cs_score_done_cycles,   FA_REG_PERF_CS_SCORE_DONE_CYCLES,   "RO");
    default_map.add_reg(perf_cs_softmax_prep_cycles, FA_REG_PERF_CS_SOFTMAX_PREP_CYCLES, "RO");
  endfunction
endclass