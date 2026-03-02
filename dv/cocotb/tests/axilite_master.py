from cocotb.triggers import RisingEdge


class AxiLiteMaster:
    def __init__(self, dut, prefix="s_axil"):
        self.dut = dut
        self.awaddr = getattr(dut, f"{prefix}_awaddr")
        self.awvalid = getattr(dut, f"{prefix}_awvalid")
        self.awready = getattr(dut, f"{prefix}_awready")
        self.wdata = getattr(dut, f"{prefix}_wdata")
        self.wstrb = getattr(dut, f"{prefix}_wstrb")
        self.wvalid = getattr(dut, f"{prefix}_wvalid")
        self.wready = getattr(dut, f"{prefix}_wready")
        self.bresp = getattr(dut, f"{prefix}_bresp")
        self.bvalid = getattr(dut, f"{prefix}_bvalid")
        self.bready = getattr(dut, f"{prefix}_bready")
        self.araddr = getattr(dut, f"{prefix}_araddr")
        self.arvalid = getattr(dut, f"{prefix}_arvalid")
        self.arready = getattr(dut, f"{prefix}_arready")
        self.rdata = getattr(dut, f"{prefix}_rdata")
        self.rresp = getattr(dut, f"{prefix}_rresp")
        self.rvalid = getattr(dut, f"{prefix}_rvalid")
        self.rready = getattr(dut, f"{prefix}_rready")

    async def reset_master(self):
        self.awaddr.value = 0
        self.awvalid.value = 0
        self.wdata.value = 0
        self.wstrb.value = 0
        self.wvalid.value = 0
        self.bready.value = 0
        self.araddr.value = 0
        self.arvalid.value = 0
        self.rready.value = 0

    async def write(self, addr: int, data: int, wstrb: int = 0xF):
        self.awaddr.value = addr
        self.awvalid.value = 1
        self.wdata.value = data & 0xFFFFFFFF
        self.wstrb.value = wstrb
        self.wvalid.value = 1

        while True:
            await RisingEdge(self.dut.clk)
            if int(self.awready.value) and int(self.wready.value):
                break

        self.awvalid.value = 0
        self.wvalid.value = 0

        self.bready.value = 1
        while True:
            await RisingEdge(self.dut.clk)
            if int(self.bvalid.value):
                break
        self.bready.value = 0

    async def read(self, addr: int) -> int:
        self.araddr.value = addr
        self.arvalid.value = 1

        while True:
            await RisingEdge(self.dut.clk)
            if int(self.arready.value):
                break

        self.arvalid.value = 0
        self.rready.value = 1

        while True:
            await RisingEdge(self.dut.clk)
            if int(self.rvalid.value):
                value = int(self.rdata.value) & 0xFFFFFFFF
                break

        self.rready.value = 0
        return value
