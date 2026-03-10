class fa_scoreboard extends uvm_component;
  `uvm_component_utils(fa_scoreboard)

  uvm_analysis_imp_axil #(fa_axil_item, fa_scoreboard) axil_imp;
  uvm_analysis_imp_axi_mem #(fa_axi_mem_item, fa_scoreboard) axi_mem_imp;

  uvm_reg_data_t perf_reads[int unsigned];
  int unsigned   dma_rd_cmd_count;
  int unsigned   dma_rd_beat_count;
  int unsigned   dma_wr_cmd_count;
  int unsigned   dma_wr_beat_count;
  int unsigned   dma_wr_resp_count;
  int unsigned   start_write_count;

  function new(string name = "fa_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    axil_imp = new("axil_imp", this);
    axi_mem_imp = new("axi_mem_imp", this);
  endfunction

  function void write_axil(fa_axil_item item);
    if (item.kind == FA_AXIL_WRITE) begin
      if ((item.addr[7:0] == FA_REG_CTRL[7:0]) && item.data[0]) begin
        start_write_count++;
      end
    end else begin
      case (item.addr[7:0])
        FA_REG_PERF_RUN_COUNT[7:0],
        FA_REG_PERF_BUSY_CYCLES[7:0],
        FA_REG_PERF_DMA_RD_CMD_COUNT[7:0],
        FA_REG_PERF_DMA_RD_BEAT_COUNT[7:0],
        FA_REG_PERF_DMA_WR_CMD_COUNT[7:0],
        FA_REG_PERF_DMA_WR_BEAT_COUNT[7:0],
        FA_REG_PERF_COMP_LAUNCH_COUNT[7:0],
        FA_REG_PERF_EXP_EVAL_COUNT[7:0],
        FA_REG_PERF_MUL_EVAL_COUNT[7:0],
        FA_REG_PERF_RECIP_REQ_COUNT[7:0],
        FA_REG_PERF_RECIP_RSP_COUNT[7:0],
        FA_REG_PERF_MS_LOAD_Q_CYCLES[7:0],
        FA_REG_PERF_MS_INIT_CONTEXT_CYCLES[7:0],
        FA_REG_PERF_MS_LOAD_K_CYCLES[7:0],
        FA_REG_PERF_MS_LOAD_V_CYCLES[7:0],
        FA_REG_PERF_MS_COMPUTE_CYCLES[7:0],
        FA_REG_PERF_MS_NORMALIZE_CYCLES[7:0],
        FA_REG_PERF_MS_WRITE_O_CYCLES[7:0],
        FA_REG_PERF_MS_NEXT_Q_CYCLES[7:0],
        FA_REG_PERF_CS_DP_RUN_CYCLES[7:0],
        FA_REG_PERF_CS_SCORE_DONE_CYCLES[7:0],
        FA_REG_PERF_CS_SOFTMAX_PREP_CYCLES[7:0]: begin
          perf_reads[item.addr[7:0]] = item.data;
        end
        default: begin
        end
      endcase
    end
  endfunction

  function void write_axi_mem(fa_axi_mem_item item);
    case (item.channel)
      FA_AXI_MEM_READ_CMD:  dma_rd_cmd_count++;
      FA_AXI_MEM_READ_BEAT: dma_rd_beat_count++;
      FA_AXI_MEM_WRITE_CMD: dma_wr_cmd_count++;
      FA_AXI_MEM_WRITE_BEAT: dma_wr_beat_count++;
      FA_AXI_MEM_WRITE_RESP: dma_wr_resp_count++;
      default: begin
      end
    endcase
  endfunction

  protected function void expect_equal(string name, uvm_reg_data_t got, uvm_reg_data_t exp);
    if (got != exp) begin
      `uvm_error(get_type_name(), $sformatf("%s mismatch: got 0x%08x exp 0x%08x", name, got, exp))
    end
  endfunction

  function void check_phase(uvm_phase phase);
    uvm_reg_data_t stage_sum;

    super.check_phase(phase);

    if (perf_reads.exists(FA_REG_PERF_RUN_COUNT)) begin
      expect_equal("perf_run_count", perf_reads[FA_REG_PERF_RUN_COUNT], start_write_count);
    end
    if (perf_reads.exists(FA_REG_PERF_DMA_RD_CMD_COUNT)) begin
      expect_equal("perf_dma_rd_cmd_count", perf_reads[FA_REG_PERF_DMA_RD_CMD_COUNT], dma_rd_cmd_count);
    end
    if (perf_reads.exists(FA_REG_PERF_DMA_RD_BEAT_COUNT)) begin
      expect_equal("perf_dma_rd_beat_count", perf_reads[FA_REG_PERF_DMA_RD_BEAT_COUNT], dma_rd_beat_count);
    end
    if (perf_reads.exists(FA_REG_PERF_DMA_WR_CMD_COUNT)) begin
      expect_equal("perf_dma_wr_cmd_count", perf_reads[FA_REG_PERF_DMA_WR_CMD_COUNT], dma_wr_cmd_count);
    end
    if (perf_reads.exists(FA_REG_PERF_DMA_WR_BEAT_COUNT)) begin
      expect_equal("perf_dma_wr_beat_count", perf_reads[FA_REG_PERF_DMA_WR_BEAT_COUNT], dma_wr_beat_count);
    end

    if (perf_reads.exists(FA_REG_PERF_BUSY_CYCLES) &&
        perf_reads.exists(FA_REG_PERF_MS_LOAD_Q_CYCLES) &&
        perf_reads.exists(FA_REG_PERF_MS_INIT_CONTEXT_CYCLES) &&
        perf_reads.exists(FA_REG_PERF_MS_LOAD_K_CYCLES) &&
        perf_reads.exists(FA_REG_PERF_MS_LOAD_V_CYCLES) &&
        perf_reads.exists(FA_REG_PERF_MS_COMPUTE_CYCLES) &&
        perf_reads.exists(FA_REG_PERF_MS_NORMALIZE_CYCLES) &&
        perf_reads.exists(FA_REG_PERF_MS_WRITE_O_CYCLES) &&
        perf_reads.exists(FA_REG_PERF_MS_NEXT_Q_CYCLES)) begin
      stage_sum = perf_reads[FA_REG_PERF_MS_LOAD_Q_CYCLES] +
                  perf_reads[FA_REG_PERF_MS_INIT_CONTEXT_CYCLES] +
                  perf_reads[FA_REG_PERF_MS_LOAD_K_CYCLES] +
                  perf_reads[FA_REG_PERF_MS_LOAD_V_CYCLES] +
                  perf_reads[FA_REG_PERF_MS_COMPUTE_CYCLES] +
                  perf_reads[FA_REG_PERF_MS_NORMALIZE_CYCLES] +
                  perf_reads[FA_REG_PERF_MS_WRITE_O_CYCLES] +
                  perf_reads[FA_REG_PERF_MS_NEXT_Q_CYCLES];
      expect_equal("perf_busy_cycles", perf_reads[FA_REG_PERF_BUSY_CYCLES], stage_sum);
    end
  endfunction
endclass