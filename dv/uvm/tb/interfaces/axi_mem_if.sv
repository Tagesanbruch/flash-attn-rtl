interface axi_mem_if #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 128,
  parameter int ID_W   = 4
) (
  input logic clk
);
  logic rst_n;

  logic [ID_W-1:0]     arid;
  logic [ADDR_W-1:0]   araddr;
  logic [7:0]          arlen;
  logic [2:0]          arsize;
  logic [1:0]          arburst;
  logic                arvalid;
  logic                arready;

  logic [ID_W-1:0]     rid;
  logic [DATA_W-1:0]   rdata;
  logic [1:0]          rresp;
  logic                rlast;
  logic                rvalid;
  logic                rready;

  logic [ID_W-1:0]     awid;
  logic [ADDR_W-1:0]   awaddr;
  logic [7:0]          awlen;
  logic [2:0]          awsize;
  logic [1:0]          awburst;
  logic                awvalid;
  logic                awready;

  logic [DATA_W-1:0]   wdata;
  logic [DATA_W/8-1:0] wstrb;
  logic                wlast;
  logic                wvalid;
  logic                wready;

  logic [ID_W-1:0]     bid;
  logic [1:0]          bresp;
  logic                bvalid;
  logic                bready;
endinterface