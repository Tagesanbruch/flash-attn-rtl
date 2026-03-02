module fa_axi_lite_regs #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 32
) (
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic [ADDR_W-1:0]    s_axil_awaddr,
  input  logic                 s_axil_awvalid,
  output logic                 s_axil_awready,
  input  logic [DATA_W-1:0]    s_axil_wdata,
  input  logic [DATA_W/8-1:0]  s_axil_wstrb,
  input  logic                 s_axil_wvalid,
  output logic                 s_axil_wready,
  output logic [1:0]           s_axil_bresp,
  output logic                 s_axil_bvalid,
  input  logic                 s_axil_bready,

  input  logic [ADDR_W-1:0]    s_axil_araddr,
  input  logic                 s_axil_arvalid,
  output logic                 s_axil_arready,
  output logic [DATA_W-1:0]    s_axil_rdata,
  output logic [1:0]           s_axil_rresp,
  output logic                 s_axil_rvalid,
  input  logic                 s_axil_rready,

  input  logic                 i_busy,
  input  logic                 i_done,
  input  logic                 i_error,
  input  logic [31:0]          i_cycles,

  output logic                 o_start_pulse,
  output logic                 o_soft_reset,
  output logic                 o_irq_en,
  output logic                 o_causal_en,
  output logic [63:0]          o_q_base,
  output logic [63:0]          o_k_base,
  output logic [63:0]          o_v_base,
  output logic [63:0]          o_o_base,
  output logic [31:0]          o_stride_bytes,
  output logic [15:0]          o_neg_large_q8_8,
  output logic [15:0]          o_scale_q8_8
);
  localparam logic [7:0] REG_CTRL         = 8'h00;
  localparam logic [7:0] REG_STATUS       = 8'h04;
  localparam logic [7:0] REG_CFG          = 8'h08;
  localparam logic [7:0] REG_Q_BASE_L     = 8'h14;
  localparam logic [7:0] REG_Q_BASE_H     = 8'h18;
  localparam logic [7:0] REG_K_BASE_L     = 8'h1C;
  localparam logic [7:0] REG_K_BASE_H     = 8'h20;
  localparam logic [7:0] REG_V_BASE_L     = 8'h24;
  localparam logic [7:0] REG_V_BASE_H     = 8'h28;
  localparam logic [7:0] REG_O_BASE_L     = 8'h2C;
  localparam logic [7:0] REG_O_BASE_H     = 8'h30;
  localparam logic [7:0] REG_STRIDE_BYTES = 8'h34;
  localparam logic [7:0] REG_NEG_LARGE    = 8'h38;
  localparam logic [7:0] REG_SCALE        = 8'h3C;
  localparam logic [7:0] REG_CYCLES       = 8'h40;

  logic [31:0] reg_ctrl;
  logic [31:0] reg_cfg;
  logic [31:0] reg_q_base_l;
  logic [31:0] reg_q_base_h;
  logic [31:0] reg_k_base_l;
  logic [31:0] reg_k_base_h;
  logic [31:0] reg_v_base_l;
  logic [31:0] reg_v_base_h;
  logic [31:0] reg_o_base_l;
  logic [31:0] reg_o_base_h;
  logic [31:0] reg_stride_bytes;
  logic [31:0] reg_neg_large;
  logic [31:0] reg_scale;

  logic done_sticky;

  logic [ADDR_W-1:0] awaddr_latched;
  logic [DATA_W-1:0] wdata_latched;
  logic aw_seen;
  logic w_seen;
  logic write_fire;

  logic [7:0] wr_addr;
  logic [7:0] rd_addr;

  always_comb begin
    wr_addr = awaddr_latched[7:0];
    rd_addr = s_axil_araddr[7:0];

    s_axil_awready = !aw_seen;
    s_axil_wready  = !w_seen;
    s_axil_bresp   = 2'b00;

    s_axil_arready = !s_axil_rvalid;
    s_axil_rresp   = 2'b00;

    s_axil_rdata = 32'd0;
    unique case (rd_addr)
      REG_CTRL:         s_axil_rdata = reg_ctrl;
      REG_STATUS:       s_axil_rdata = {29'd0, i_error, done_sticky, i_busy};
      REG_CFG:          s_axil_rdata = reg_cfg;
      REG_Q_BASE_L:     s_axil_rdata = reg_q_base_l;
      REG_Q_BASE_H:     s_axil_rdata = reg_q_base_h;
      REG_K_BASE_L:     s_axil_rdata = reg_k_base_l;
      REG_K_BASE_H:     s_axil_rdata = reg_k_base_h;
      REG_V_BASE_L:     s_axil_rdata = reg_v_base_l;
      REG_V_BASE_H:     s_axil_rdata = reg_v_base_h;
      REG_O_BASE_L:     s_axil_rdata = reg_o_base_l;
      REG_O_BASE_H:     s_axil_rdata = reg_o_base_h;
      REG_STRIDE_BYTES: s_axil_rdata = reg_stride_bytes;
      REG_NEG_LARGE:    s_axil_rdata = reg_neg_large;
      REG_SCALE:        s_axil_rdata = reg_scale;
      REG_CYCLES:       s_axil_rdata = i_cycles;
      default:          s_axil_rdata = 32'd0;
    endcase
  end

  assign write_fire = aw_seen && w_seen && !s_axil_bvalid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_seen <= 1'b0;
      w_seen <= 1'b0;
      awaddr_latched <= '0;
      wdata_latched <= '0;
      s_axil_bvalid <= 1'b0;
      s_axil_rvalid <= 1'b0;

      reg_ctrl <= 32'd0;
      reg_cfg <= 32'd0;
      reg_q_base_l <= 32'd0;
      reg_q_base_h <= 32'd0;
      reg_k_base_l <= 32'd0;
      reg_k_base_h <= 32'd0;
      reg_v_base_l <= 32'd0;
      reg_v_base_h <= 32'd0;
      reg_o_base_l <= 32'd0;
      reg_o_base_h <= 32'd0;
      reg_stride_bytes <= 32'd128;
      reg_neg_large <= 32'hFFFF_8000;
      reg_scale <= 32'd32;
      done_sticky <= 1'b0;
      o_start_pulse <= 1'b0;
    end else begin
      o_start_pulse <= 1'b0;

      if (s_axil_awvalid && s_axil_awready) begin
        aw_seen <= 1'b1;
        awaddr_latched <= s_axil_awaddr;
      end
      if (s_axil_wvalid && s_axil_wready) begin
        w_seen <= 1'b1;
        wdata_latched <= s_axil_wdata;
      end

      if (write_fire) begin
        s_axil_bvalid <= 1'b1;
        aw_seen <= 1'b0;
        w_seen <= 1'b0;

        unique case (wr_addr)
          REG_CTRL: begin
            reg_ctrl[2:1] <= wdata_latched[2:1];
            if (wdata_latched[0]) begin
              o_start_pulse <= 1'b1;
              done_sticky <= 1'b0;
            end
          end
          REG_STATUS: begin
            if (wdata_latched[1]) begin
              done_sticky <= 1'b0;
            end
          end
          REG_CFG:          reg_cfg <= wdata_latched;
          REG_Q_BASE_L:     reg_q_base_l <= wdata_latched;
          REG_Q_BASE_H:     reg_q_base_h <= wdata_latched;
          REG_K_BASE_L:     reg_k_base_l <= wdata_latched;
          REG_K_BASE_H:     reg_k_base_h <= wdata_latched;
          REG_V_BASE_L:     reg_v_base_l <= wdata_latched;
          REG_V_BASE_H:     reg_v_base_h <= wdata_latched;
          REG_O_BASE_L:     reg_o_base_l <= wdata_latched;
          REG_O_BASE_H:     reg_o_base_h <= wdata_latched;
          REG_STRIDE_BYTES: reg_stride_bytes <= wdata_latched;
          REG_NEG_LARGE:    reg_neg_large <= wdata_latched;
          REG_SCALE:        reg_scale <= wdata_latched;
          default: begin end
        endcase
      end

      if (s_axil_bvalid && s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
      end

      if (s_axil_arvalid && s_axil_arready) begin
        s_axil_rvalid <= 1'b1;
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end

      if (i_done) begin
        done_sticky <= 1'b1;
      end
    end
  end

  assign o_soft_reset = reg_ctrl[1];
  assign o_irq_en = reg_ctrl[2];
  assign o_causal_en = reg_cfg[0];

  assign o_q_base = {reg_q_base_h, reg_q_base_l};
  assign o_k_base = {reg_k_base_h, reg_k_base_l};
  assign o_v_base = {reg_v_base_h, reg_v_base_l};
  assign o_o_base = {reg_o_base_h, reg_o_base_l};
  assign o_stride_bytes = reg_stride_bytes;
  assign o_neg_large_q8_8 = reg_neg_large[15:0];
  assign o_scale_q8_8 = reg_scale[15:0];
endmodule
