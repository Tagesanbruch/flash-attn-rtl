package fa_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `uvm_analysis_imp_decl(_axil)
  `uvm_analysis_imp_decl(_axi_mem)

  typedef virtual axil_if#(32, 32) fa_axil_vif_t;
  typedef virtual axi_mem_if#(32, 128, 4) fa_axi_mem_vif_t;

  typedef enum bit [0:0] {
    FA_AXIL_READ  = 1'b0,
    FA_AXIL_WRITE = 1'b1
  } fa_axil_kind_e;

  typedef enum bit [2:0] {
    FA_AXI_MEM_READ_CMD  = 3'd0,
    FA_AXI_MEM_READ_BEAT = 3'd1,
    FA_AXI_MEM_WRITE_CMD = 3'd2,
    FA_AXI_MEM_WRITE_BEAT = 3'd3,
    FA_AXI_MEM_WRITE_RESP = 3'd4
  } fa_axi_mem_channel_e;

  localparam int unsigned FA_REG_CTRL                         = 'h00;
  localparam int unsigned FA_REG_STATUS                       = 'h04;
  localparam int unsigned FA_REG_CFG                          = 'h08;
  localparam int unsigned FA_REG_Q_BASE_L                     = 'h14;
  localparam int unsigned FA_REG_Q_BASE_H                     = 'h18;
  localparam int unsigned FA_REG_K_BASE_L                     = 'h1c;
  localparam int unsigned FA_REG_K_BASE_H                     = 'h20;
  localparam int unsigned FA_REG_V_BASE_L                     = 'h24;
  localparam int unsigned FA_REG_V_BASE_H                     = 'h28;
  localparam int unsigned FA_REG_O_BASE_L                     = 'h2c;
  localparam int unsigned FA_REG_O_BASE_H                     = 'h30;
  localparam int unsigned FA_REG_STRIDE_BYTES                 = 'h34;
  localparam int unsigned FA_REG_NEG_LARGE                    = 'h38;
  localparam int unsigned FA_REG_SCALE                        = 'h3c;
  localparam int unsigned FA_REG_CYCLES                       = 'h40;
  localparam int unsigned FA_REG_PERF_RUN_COUNT               = 'h80;
  localparam int unsigned FA_REG_PERF_BUSY_CYCLES             = 'h84;
  localparam int unsigned FA_REG_PERF_DMA_RD_CMD_COUNT        = 'h88;
  localparam int unsigned FA_REG_PERF_DMA_RD_BEAT_COUNT       = 'h8c;
  localparam int unsigned FA_REG_PERF_DMA_WR_CMD_COUNT        = 'h90;
  localparam int unsigned FA_REG_PERF_DMA_WR_BEAT_COUNT       = 'h94;
  localparam int unsigned FA_REG_PERF_COMP_LAUNCH_COUNT       = 'h98;
  localparam int unsigned FA_REG_PERF_EXP_EVAL_COUNT          = 'h9c;
  localparam int unsigned FA_REG_PERF_MUL_EVAL_COUNT          = 'ha0;
  localparam int unsigned FA_REG_PERF_RECIP_REQ_COUNT         = 'ha4;
  localparam int unsigned FA_REG_PERF_RECIP_RSP_COUNT         = 'ha8;
  localparam int unsigned FA_REG_PERF_MS_LOAD_Q_CYCLES        = 'hac;
  localparam int unsigned FA_REG_PERF_MS_INIT_CONTEXT_CYCLES  = 'hb0;
  localparam int unsigned FA_REG_PERF_MS_LOAD_K_CYCLES        = 'hb4;
  localparam int unsigned FA_REG_PERF_MS_LOAD_V_CYCLES        = 'hb8;
  localparam int unsigned FA_REG_PERF_MS_COMPUTE_CYCLES       = 'hbc;
  localparam int unsigned FA_REG_PERF_MS_NORMALIZE_CYCLES     = 'hc0;
  localparam int unsigned FA_REG_PERF_MS_WRITE_O_CYCLES       = 'hc4;
  localparam int unsigned FA_REG_PERF_MS_NEXT_Q_CYCLES        = 'hc8;
  localparam int unsigned FA_REG_PERF_CS_DP_RUN_CYCLES        = 'hcc;
  localparam int unsigned FA_REG_PERF_CS_SCORE_DONE_CYCLES    = 'hd0;
  localparam int unsigned FA_REG_PERF_CS_SOFTMAX_PREP_CYCLES  = 'hd4;

  class fa_axil_agent_cfg extends uvm_object;
    `uvm_object_utils(fa_axil_agent_cfg)

    fa_axil_vif_t vif;
    uvm_active_passive_enum is_active = UVM_ACTIVE;

    function new(string name = "fa_axil_agent_cfg");
      super.new(name);
    endfunction
  endclass

  class fa_axi_mem_agent_cfg extends uvm_object;
    `uvm_object_utils(fa_axi_mem_agent_cfg)

    fa_axi_mem_vif_t vif;
    uvm_active_passive_enum is_active = UVM_ACTIVE;
    int unsigned read_latency = 0;
    int unsigned write_resp_latency = 0;
    bit randomize_latency = 0;
    int unsigned max_random_latency = 4;
    bit [127:0] mem[longint unsigned];

    function new(string name = "fa_axi_mem_agent_cfg");
      super.new(name);
    endfunction

    function void set_word(longint unsigned addr, bit [127:0] data);
      mem[addr] = data;
    endfunction

    function bit [127:0] get_word(longint unsigned addr);
      if (mem.exists(addr)) begin
        return mem[addr];
      end
      return '0;
    endfunction
  endclass

  `include "agents/axil/fa_axil_item.sv"
  `include "agents/axil/fa_axil_sequencer.sv"
  `include "agents/axil/fa_axil_driver.sv"
  `include "agents/axil/fa_axil_monitor.sv"
  `include "agents/axil/fa_axil_agent.sv"

  `include "agents/axi_mem/fa_axi_mem_item.sv"
  `include "agents/axi_mem/fa_axi_mem_sequencer.sv"
  `include "agents/axi_mem/fa_axi_mem_driver.sv"
  `include "agents/axi_mem/fa_axi_mem_monitor.sv"
  `include "agents/axi_mem/fa_axi_mem_agent.sv"

  `include "regmodel/fa_attention_reg_block.sv"
  `include "regmodel/fa_attention_reg_adapter.sv"
  `include "regmodel/fa_attention_reg_predictor.sv"

  `include "env/fa_base_env.sv"
  `include "env/fa_virtual_sequencer.sv"
  `include "env/fa_scoreboard.sv"
  `include "env/fa_attention_top_env.sv"
endpackage