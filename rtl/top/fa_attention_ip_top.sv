module fa_attention_ip_top #(
  parameter int AXIL_ADDR_W = 32,
  parameter int AXIL_DATA_W = 32,
  parameter int AXI_DATA_W  = 128,
  parameter int AXI_ADDR_W  = 32,
  parameter int AXI_ID_W    = 4,
  parameter int SEQ_LEN     = 256
) (
  input  logic                        clk,
  input  logic                        rst_n,

  // ==== AXI4-Lite slave (control) ====
  input  logic [AXIL_ADDR_W-1:0]      s_axil_awaddr,
  input  logic                        s_axil_awvalid,
  output logic                        s_axil_awready,
  input  logic [AXIL_DATA_W-1:0]      s_axil_wdata,
  input  logic [AXIL_DATA_W/8-1:0]    s_axil_wstrb,
  input  logic                        s_axil_wvalid,
  output logic                        s_axil_wready,
  output logic [1:0]                  s_axil_bresp,
  output logic                        s_axil_bvalid,
  input  logic                        s_axil_bready,

  input  logic [AXIL_ADDR_W-1:0]      s_axil_araddr,
  input  logic                        s_axil_arvalid,
  output logic                        s_axil_arready,
  output logic [AXIL_DATA_W-1:0]      s_axil_rdata,
  output logic [1:0]                  s_axil_rresp,
  output logic                        s_axil_rvalid,
  input  logic                        s_axil_rready,

  // ==== AXI4 Master (data DMA) ====
  // -- AR --
  output logic [AXI_ID_W-1:0]        m_axi_arid,
  output logic [AXI_ADDR_W-1:0]      m_axi_araddr,
  output logic [7:0]                  m_axi_arlen,
  output logic [2:0]                  m_axi_arsize,
  output logic [1:0]                  m_axi_arburst,
  output logic                        m_axi_arvalid,
  input  logic                        m_axi_arready,
  // -- R --
  input  logic [AXI_ID_W-1:0]        m_axi_rid,
  input  logic [AXI_DATA_W-1:0]      m_axi_rdata,
  input  logic [1:0]                  m_axi_rresp,
  input  logic                        m_axi_rlast,
  input  logic                        m_axi_rvalid,
  output logic                        m_axi_rready,
  // -- AW --
  output logic [AXI_ID_W-1:0]        m_axi_awid,
  output logic [AXI_ADDR_W-1:0]      m_axi_awaddr,
  output logic [7:0]                  m_axi_awlen,
  output logic [2:0]                  m_axi_awsize,
  output logic [1:0]                  m_axi_awburst,
  output logic                        m_axi_awvalid,
  input  logic                        m_axi_awready,
  // -- W --
  output logic [AXI_DATA_W-1:0]      m_axi_wdata,
  output logic [AXI_DATA_W/8-1:0]    m_axi_wstrb,
  output logic                        m_axi_wlast,
  output logic                        m_axi_wvalid,
  input  logic                        m_axi_wready,
  // -- B --
  input  logic [AXI_ID_W-1:0]        m_axi_bid,
  input  logic [1:0]                  m_axi_bresp,
  input  logic                        m_axi_bvalid,
  output logic                        m_axi_bready
);

`ifdef FA_UVM_DISABLE_REGS_PERF
`define FA_UVM_DISABLE_REGS
`define FA_UVM_DISABLE_PERF
`endif

  // ---- Internal wires ----
  logic        start_pulse;
  logic        soft_reset;
  logic        irq_en;
  logic        causal_en;
  logic [63:0] q_base, k_base, v_base, o_base;
  logic [31:0] stride_bytes;
  logic [31:0] num_heads;
  logic [31:0] head_stride_bytes;
  logic [15:0] neg_large_q8_8;
  logic [15:0] scale_q8_8;
  logic        core_busy, core_done, core_error;
  logic [31:0] core_cycles;
  logic        run_busy, run_done, run_error;
  logic [31:0] run_cycles;
  logic        core_start_pulse;
  logic        launch_pending;
  logic [31:0] active_head_idx;
  logic [31:0] completed_head_cycles;
  logic [31:0] run_cycles_hold;
  logic        run_error_latched;
  logic [31:0] effective_num_heads;
  logic [31:0] effective_head_stride_bytes;
  logic [63:0] active_head_byte_offset;
  logic [63:0] core_q_base, core_k_base, core_v_base, core_o_base;

  logic        perf_ms_load_q;
  logic        perf_ms_init_context;
  logic        perf_ms_load_k;
  logic        perf_ms_load_v;
  logic        perf_ms_compute;
  logic        perf_ms_normalize;
  logic        perf_ms_write_o;
  logic        perf_ms_next_q;
  logic        perf_cs_dp_run;
  logic        perf_cs_score_done;
  logic        perf_cs_softmax_prep;
  logic        perf_comp_launch;
  logic [1:0]  perf_active_rows;
  logic        perf_norm_recip_req;
  logic        perf_norm_recip_rsp;

  logic [31:0] perf_run_count;
  logic [31:0] perf_busy_cycles;
  logic [31:0] perf_dma_rd_cmd_count;
  logic [31:0] perf_dma_rd_beat_count;
  logic [31:0] perf_dma_wr_cmd_count;
  logic [31:0] perf_dma_wr_beat_count;
  logic [31:0] perf_comp_launch_count;
  logic [31:0] perf_exp_eval_count;
  logic [31:0] perf_mul_eval_count;
  logic [31:0] perf_recip_req_count;
  logic [31:0] perf_recip_rsp_count;
  logic [31:0] perf_ms_load_q_cycles;
  logic [31:0] perf_ms_init_context_cycles;
  logic [31:0] perf_ms_load_k_cycles;
  logic [31:0] perf_ms_load_v_cycles;
  logic [31:0] perf_ms_compute_cycles;
  logic [31:0] perf_ms_normalize_cycles;
  logic [31:0] perf_ms_write_o_cycles;
  logic [31:0] perf_ms_next_q_cycles;
  logic [31:0] perf_cs_dp_run_cycles;
  logic [31:0] perf_cs_score_done_cycles;
  logic [31:0] perf_cs_softmax_prep_cycles;

  // DMA reader <-> core
  logic        dma_rd_cmd_valid, dma_rd_cmd_ready;
  logic [31:0] dma_rd_cmd_addr;
  logic [15:0] dma_rd_cmd_len;
  logic        dma_rd_out_valid, dma_rd_out_ready;
  logic [AXI_DATA_W-1:0] dma_rd_out_data;
  logic        dma_rd_out_last;
  logic        dma_rd_error;
  logic [31:0] rd_bytes;

  // DMA writer <-> core
  logic        dma_wr_cmd_valid, dma_wr_cmd_ready;
  logic [31:0] dma_wr_cmd_addr;
  logic [15:0] dma_wr_cmd_len;
  logic        dma_wr_in_valid, dma_wr_in_ready;
  logic [AXI_DATA_W-1:0] dma_wr_in_data;
  logic        dma_wr_in_last;
  logic        dma_wr_error;
  logic [31:0] wr_bytes;

  // ==== Register file ====
`ifndef FA_UVM_DISABLE_REGS
  fa_axi_lite_regs u_regs (
    .clk(clk), .rst_n(rst_n),
    .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
    .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),
    .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
    .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
    .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp), .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
    .i_busy(run_busy), .i_done(run_done), .i_error(run_error), .i_cycles(run_cycles),
    .i_perf_run_count(perf_run_count), .i_perf_busy_cycles(perf_busy_cycles),
    .i_perf_dma_rd_cmd_count(perf_dma_rd_cmd_count), .i_perf_dma_rd_beat_count(perf_dma_rd_beat_count),
    .i_perf_dma_wr_cmd_count(perf_dma_wr_cmd_count), .i_perf_dma_wr_beat_count(perf_dma_wr_beat_count),
    .i_perf_comp_launch_count(perf_comp_launch_count), .i_perf_exp_eval_count(perf_exp_eval_count),
    .i_perf_mul_eval_count(perf_mul_eval_count), .i_perf_recip_req_count(perf_recip_req_count),
    .i_perf_recip_rsp_count(perf_recip_rsp_count), .i_perf_ms_load_q_cycles(perf_ms_load_q_cycles),
    .i_perf_ms_init_context_cycles(perf_ms_init_context_cycles), .i_perf_ms_load_k_cycles(perf_ms_load_k_cycles),
    .i_perf_ms_load_v_cycles(perf_ms_load_v_cycles), .i_perf_ms_compute_cycles(perf_ms_compute_cycles),
    .i_perf_ms_normalize_cycles(perf_ms_normalize_cycles), .i_perf_ms_write_o_cycles(perf_ms_write_o_cycles),
    .i_perf_ms_next_q_cycles(perf_ms_next_q_cycles), .i_perf_cs_dp_run_cycles(perf_cs_dp_run_cycles),
    .i_perf_cs_score_done_cycles(perf_cs_score_done_cycles), .i_perf_cs_softmax_prep_cycles(perf_cs_softmax_prep_cycles),
    .o_start_pulse(start_pulse), .o_soft_reset(soft_reset), .o_irq_en(irq_en), .o_causal_en(causal_en),
    .o_q_base(q_base), .o_k_base(k_base), .o_v_base(v_base), .o_o_base(o_base),
    .o_stride_bytes(stride_bytes), .o_num_heads(num_heads), .o_head_stride_bytes(head_stride_bytes),
    .o_neg_large_q8_8(neg_large_q8_8), .o_scale_q8_8(scale_q8_8)
  );
`else
  assign s_axil_awready = 1'b0;
  assign s_axil_wready = 1'b0;
  assign s_axil_bresp = 2'b00;
  assign s_axil_bvalid = 1'b0;
  assign s_axil_arready = 1'b0;
  assign s_axil_rdata = '0;
  assign s_axil_rresp = 2'b00;
  assign s_axil_rvalid = 1'b0;
  assign start_pulse = 1'b0;
  assign soft_reset = 1'b0;
  assign irq_en = 1'b0;
  assign causal_en = 1'b0;
  assign q_base = 64'd0;
  assign k_base = 64'd0;
  assign v_base = 64'd0;
  assign o_base = 64'd0;
  assign stride_bytes = 32'd0;
  assign num_heads = 32'd1;
  assign head_stride_bytes = 32'd0;
  assign neg_large_q8_8 = 16'd0;
  assign scale_q8_8 = 16'd0;
`endif

  assign effective_num_heads = (num_heads == 32'd0) ? 32'd1 : num_heads;
  assign effective_head_stride_bytes = (head_stride_bytes == 32'd0) ? (stride_bytes * SEQ_LEN) : head_stride_bytes;
  assign active_head_byte_offset = active_head_idx * effective_head_stride_bytes;
  assign core_q_base = q_base + active_head_byte_offset;
  assign core_k_base = k_base + active_head_byte_offset;
  assign core_v_base = v_base + active_head_byte_offset;
  assign core_o_base = o_base + active_head_byte_offset;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      launch_pending <= 1'b0;
      active_head_idx <= 32'd0;
      completed_head_cycles <= 32'd0;
      run_cycles_hold <= 32'd0;
      run_done <= 1'b0;
      run_error_latched <= 1'b0;
      core_start_pulse <= 1'b0;
    end else begin
      run_done <= 1'b0;
      core_start_pulse <= 1'b0;

      if (soft_reset) begin
        launch_pending <= 1'b0;
        active_head_idx <= 32'd0;
        run_cycles_hold <= completed_head_cycles + core_cycles;
        run_error_latched <= 1'b0;
      end else begin
        if (start_pulse && !run_busy) begin
          launch_pending <= 1'b1;
          active_head_idx <= 32'd0;
          completed_head_cycles <= 32'd0;
          run_cycles_hold <= 32'd0;
          run_error_latched <= 1'b0;
        end else if (core_done) begin
          completed_head_cycles <= completed_head_cycles + core_cycles;
          run_cycles_hold <= completed_head_cycles + core_cycles;
          run_error_latched <= run_error_latched | core_error;
          if ((active_head_idx + 32'd1) < effective_num_heads) begin
            active_head_idx <= active_head_idx + 32'd1;
            launch_pending <= 1'b1;
          end else begin
            launch_pending <= 1'b0;
            run_done <= 1'b1;
          end
        end else if (launch_pending && !core_busy && !core_done) begin
          core_start_pulse <= 1'b1;
          launch_pending <= 1'b0;
        end else if (core_busy) begin
          run_cycles_hold <= completed_head_cycles + core_cycles;
        end
      end
    end
  end

  assign run_busy = core_busy || launch_pending;
  assign run_error = run_error_latched | core_error;
  assign run_cycles = run_cycles_hold;

`ifndef FA_UVM_DISABLE_PERF
  fa_perf_counters u_perf (
    .clk(clk),
    .rst_n(rst_n),
    .i_run_start(start_pulse),
    .i_soft_reset(soft_reset),
    .i_ms_load_q(perf_ms_load_q),
    .i_ms_init_context(perf_ms_init_context),
    .i_ms_load_k(perf_ms_load_k),
    .i_ms_load_v(perf_ms_load_v),
    .i_ms_compute(perf_ms_compute),
    .i_ms_normalize(perf_ms_normalize),
    .i_ms_write_o(perf_ms_write_o),
    .i_ms_next_q(perf_ms_next_q),
    .i_cs_dp_run(perf_cs_dp_run),
    .i_cs_score_done(perf_cs_score_done),
    .i_cs_softmax_prep(perf_cs_softmax_prep),
    .i_comp_launch(perf_comp_launch),
    .i_active_rows(perf_active_rows),
    .i_norm_recip_req(perf_norm_recip_req),
    .i_norm_recip_rsp(perf_norm_recip_rsp),
    .i_dma_rd_cmd_fire(m_axi_arvalid && m_axi_arready),
    .i_dma_rd_beat_fire(dma_rd_out_valid && dma_rd_out_ready),
    .i_dma_wr_cmd_fire(m_axi_awvalid && m_axi_awready),
    .i_dma_wr_beat_fire(dma_wr_in_valid && dma_wr_in_ready),
    .o_run_count(perf_run_count),
    .o_busy_cycles(perf_busy_cycles),
    .o_dma_rd_cmd_count(perf_dma_rd_cmd_count),
    .o_dma_rd_beat_count(perf_dma_rd_beat_count),
    .o_dma_wr_cmd_count(perf_dma_wr_cmd_count),
    .o_dma_wr_beat_count(perf_dma_wr_beat_count),
    .o_comp_launch_count(perf_comp_launch_count),
    .o_exp_eval_count(perf_exp_eval_count),
    .o_mul_eval_count(perf_mul_eval_count),
    .o_recip_req_count(perf_recip_req_count),
    .o_recip_rsp_count(perf_recip_rsp_count),
    .o_ms_load_q_cycles(perf_ms_load_q_cycles),
    .o_ms_init_context_cycles(perf_ms_init_context_cycles),
    .o_ms_load_k_cycles(perf_ms_load_k_cycles),
    .o_ms_load_v_cycles(perf_ms_load_v_cycles),
    .o_ms_compute_cycles(perf_ms_compute_cycles),
    .o_ms_normalize_cycles(perf_ms_normalize_cycles),
    .o_ms_write_o_cycles(perf_ms_write_o_cycles),
    .o_ms_next_q_cycles(perf_ms_next_q_cycles),
    .o_cs_dp_run_cycles(perf_cs_dp_run_cycles),
    .o_cs_score_done_cycles(perf_cs_score_done_cycles),
    .o_cs_softmax_prep_cycles(perf_cs_softmax_prep_cycles)
  );
`else
  assign perf_run_count = 32'd0;
  assign perf_busy_cycles = 32'd0;
  assign perf_dma_rd_cmd_count = 32'd0;
  assign perf_dma_rd_beat_count = 32'd0;
  assign perf_dma_wr_cmd_count = 32'd0;
  assign perf_dma_wr_beat_count = 32'd0;
  assign perf_comp_launch_count = 32'd0;
  assign perf_exp_eval_count = 32'd0;
  assign perf_mul_eval_count = 32'd0;
  assign perf_recip_req_count = 32'd0;
  assign perf_recip_rsp_count = 32'd0;
  assign perf_ms_load_q_cycles = 32'd0;
  assign perf_ms_init_context_cycles = 32'd0;
  assign perf_ms_load_k_cycles = 32'd0;
  assign perf_ms_load_v_cycles = 32'd0;
  assign perf_ms_compute_cycles = 32'd0;
  assign perf_ms_normalize_cycles = 32'd0;
  assign perf_ms_write_o_cycles = 32'd0;
  assign perf_ms_next_q_cycles = 32'd0;
  assign perf_cs_dp_run_cycles = 32'd0;
  assign perf_cs_score_done_cycles = 32'd0;
  assign perf_cs_softmax_prep_cycles = 32'd0;
`endif

  // ==== DMA Reader ====
`ifndef FA_UVM_DISABLE_DMA
  fa_dma_reader #(
    .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W)
  ) u_dma_rd (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(dma_rd_cmd_valid), .cmd_ready(dma_rd_cmd_ready),
    .cmd_addr(dma_rd_cmd_addr), .cmd_len(dma_rd_cmd_len),
    .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
    .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
    .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
    .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
    .out_valid(dma_rd_out_valid), .out_data(dma_rd_out_data),
    .out_last(dma_rd_out_last), .out_ready(dma_rd_out_ready),
    .error(dma_rd_error), .rd_bytes(rd_bytes)
  );

  // ==== DMA Writer ====
  fa_dma_writer #(
    .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W)
  ) u_dma_wr (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(dma_wr_cmd_valid), .cmd_ready(dma_wr_cmd_ready),
    .cmd_addr(dma_wr_cmd_addr), .cmd_len(dma_wr_cmd_len),
    .in_valid(dma_wr_in_valid), .in_ready(dma_wr_in_ready),
    .in_data(dma_wr_in_data), .in_last(dma_wr_in_last),
    .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
    .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
    .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
    .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
    .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
    .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
    .error(dma_wr_error), .wr_bytes(wr_bytes)
  );
`else
  assign m_axi_arid = '0;
  assign m_axi_araddr = '0;
  assign m_axi_arlen = '0;
  assign m_axi_arsize = '0;
  assign m_axi_arburst = '0;
  assign m_axi_arvalid = 1'b0;
  assign m_axi_rready = 1'b0;
  assign m_axi_awid = '0;
  assign m_axi_awaddr = '0;
  assign m_axi_awlen = '0;
  assign m_axi_awsize = '0;
  assign m_axi_awburst = '0;
  assign m_axi_awvalid = 1'b0;
  assign m_axi_wdata = '0;
  assign m_axi_wstrb = '0;
  assign m_axi_wlast = 1'b0;
  assign m_axi_wvalid = 1'b0;
  assign m_axi_bready = 1'b0;
  assign dma_rd_cmd_ready = 1'b0;
  assign dma_rd_out_valid = 1'b0;
  assign dma_rd_out_data = '0;
  assign dma_rd_out_last = 1'b0;
  assign dma_rd_error = 1'b0;
  assign rd_bytes = 32'd0;
  assign dma_wr_cmd_ready = 1'b0;
  assign dma_wr_in_ready = 1'b0;
  assign dma_wr_error = 1'b0;
  assign wr_bytes = 32'd0;
`endif

  // ==== Attention Core ====
`ifndef FA_UVM_DISABLE_CORE
  fa_attention_core u_core (
    .clk(clk), .rst_n(rst_n),
    .i_start(core_start_pulse), .i_soft_reset(soft_reset),
    .i_causal_en(causal_en), .i_scale_q8_8(scale_q8_8),
    .i_neg_large_q8_8(neg_large_q8_8),
    .o_busy(core_busy), .o_done(core_done), .o_error(core_error), .o_cycles(core_cycles),
    .i_q_base(core_q_base), .i_k_base(core_k_base), .i_v_base(core_v_base), .i_o_base(core_o_base),
    .i_stride_bytes(stride_bytes),
    .dma_rd_cmd_valid(dma_rd_cmd_valid), .dma_rd_cmd_ready(dma_rd_cmd_ready),
    .dma_rd_cmd_addr(dma_rd_cmd_addr), .dma_rd_cmd_len(dma_rd_cmd_len),
    .dma_rd_data_valid(dma_rd_out_valid), .dma_rd_data_ready(dma_rd_out_ready),
    .dma_rd_data(dma_rd_out_data), .dma_rd_data_last(dma_rd_out_last),
    .dma_wr_cmd_valid(dma_wr_cmd_valid), .dma_wr_cmd_ready(dma_wr_cmd_ready),
    .dma_wr_cmd_addr(dma_wr_cmd_addr), .dma_wr_cmd_len(dma_wr_cmd_len),
    .dma_wr_data_valid(dma_wr_in_valid), .dma_wr_data_ready(dma_wr_in_ready),
    .dma_wr_data(dma_wr_in_data), .dma_wr_data_last(dma_wr_in_last),
    .o_perf_ms_load_q(perf_ms_load_q),
    .o_perf_ms_init_context(perf_ms_init_context),
    .o_perf_ms_load_k(perf_ms_load_k),
    .o_perf_ms_load_v(perf_ms_load_v),
    .o_perf_ms_compute(perf_ms_compute),
    .o_perf_ms_normalize(perf_ms_normalize),
    .o_perf_ms_write_o(perf_ms_write_o),
    .o_perf_ms_next_q(perf_ms_next_q),
    .o_perf_cs_dp_run(perf_cs_dp_run),
    .o_perf_cs_score_done(perf_cs_score_done),
    .o_perf_cs_softmax_prep(perf_cs_softmax_prep),
    .o_perf_comp_launch(perf_comp_launch),
    .o_perf_active_rows(perf_active_rows),
    .o_perf_norm_recip_req(perf_norm_recip_req),
    .o_perf_norm_recip_rsp(perf_norm_recip_rsp)
  );
`else
  assign core_busy = 1'b0;
  assign core_done = 1'b0;
  assign core_error = 1'b0;
  assign core_cycles = 32'd0;
  assign dma_rd_cmd_valid = 1'b0;
  assign dma_rd_cmd_addr = 32'd0;
  assign dma_rd_cmd_len = 16'd0;
  assign dma_rd_out_ready = 1'b0;
  assign dma_wr_cmd_valid = 1'b0;
  assign dma_wr_cmd_addr = 32'd0;
  assign dma_wr_cmd_len = 16'd0;
  assign dma_wr_in_valid = 1'b0;
  assign dma_wr_in_data = '0;
  assign dma_wr_in_last = 1'b0;
  assign perf_ms_load_q = 1'b0;
  assign perf_ms_init_context = 1'b0;
  assign perf_ms_load_k = 1'b0;
  assign perf_ms_load_v = 1'b0;
  assign perf_ms_compute = 1'b0;
  assign perf_ms_normalize = 1'b0;
  assign perf_ms_write_o = 1'b0;
  assign perf_ms_next_q = 1'b0;
  assign perf_cs_dp_run = 1'b0;
  assign perf_cs_score_done = 1'b0;
  assign perf_cs_softmax_prep = 1'b0;
  assign perf_comp_launch = 1'b0;
  assign perf_active_rows = 2'b00;
  assign perf_norm_recip_req = 1'b0;
  assign perf_norm_recip_rsp = 1'b0;
`endif

  // Error aggregation
  logic unused_irq;
  assign unused_irq = irq_en;
endmodule
