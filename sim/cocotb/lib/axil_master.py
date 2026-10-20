# SPDX-License-Identifier: Apache-2.0
"""AXI4-Lite master with the timing of the emacZero Verilog benches' tasks.

Every eth_mac_sys bench in sim/tb/ (tb_eth_mac_sys*.v, tb_gmii_*.v,
tb_rgmii_*.v, ...) carries the same two tasks:

    task axi_write(addr, data);              task axi_read(addr, output data);
        @(negedge clk);                          @(negedge clk);
        awaddr=addr; awvalid=1;                  araddr=addr; arvalid=1;
        wdata=data; wstrb=4'hF; wvalid=1;        rready=1;
        bready=1;                                @(posedge clk);
        @(posedge clk);                          while (!rvalid) @(posedge clk);
        while (!bvalid) @(posedge clk);          data = rdata;
        @(negedge clk);                          @(negedge clk);
        awvalid=0; wvalid=0; bready=0;           arvalid=0; rready=0;

`AxiLiteMaster.write` / `.read` reproduce them cycle for cycle:

  * Inputs are driven on the falling edge of `clk`.
  * `while (!bvalid) @(posedge clk)` tests bvalid as it was just before each
    rising edge (the value a flop would sample there). Here that value is read
    settled (ReadOnly) in the half cycle before the edge, which is the same
    value on Icarus and GHDL and free of delta-cycle races. The task returns
    past the rising edge at which bvalid / rvalid was high, so the slave sees
    bready / rready high at that edge (the response handshake completes), and
    the valids / readies drop on the next falling edge.
  * awvalid and wvalid are both raised together and held until the response,
    as the benches do (not released on awready / wready).
  * `read` returns rdata as sampled at that same edge. A value with X/Z/U bits
    comes back as its string form (e.g. "0000XXXX..."), so a comparison with
    an int fails the way `===` does in the bench.

Signals are found as `<prefix><name>` on `dut` (default prefix "s_axi_",
names awaddr awvalid wdata wstrb wvalid bready bvalid araddr arvalid rready
rvalid rdata); awready / wready / arready / bresp / rresp are not needed. The
master only drives a bus between calls through idle(); calls must not overlap.

    axil = AxiLiteMaster(dut, dut.clk)   # drives the idle values
    await axil.write(0x04, 0x7)
    val = await axil.read(0x04)
"""
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge


def _sample(sig):
    v = sig.value
    return int(v) if v.is_resolvable else str(v)


class AxiLiteMaster:
    def __init__(self, dut, clk, prefix="s_axi_", idle=True):
        self.clk = clk
        g = lambda n: getattr(dut, prefix + n)  # noqa: E731
        self.awaddr, self.awvalid = g("awaddr"), g("awvalid")
        self.wdata, self.wstrb, self.wvalid = g("wdata"), g("wstrb"), g("wvalid")
        self.bready, self.bvalid = g("bready"), g("bvalid")
        self.araddr, self.arvalid = g("araddr"), g("arvalid")
        self.rready, self.rvalid, self.rdata = g("rready"), g("rvalid"), g("rdata")
        if idle:
            self.idle()

    def idle(self):
        """The benches' reset values: every master output 0."""
        for s in (self.awaddr, self.awvalid, self.wdata, self.wstrb, self.wvalid,
                  self.bready, self.araddr, self.arvalid, self.rready):
            s.value = 0

    async def _wait_valid(self, valid, data=None):
        """Called right after a falling-edge drive. Returns past the first
        rising edge at which `valid` was high (sampled settled before it),
        with `data` sampled at the same point."""
        while True:
            await ReadOnly()
            v = valid.value
            hit = v.is_resolvable and int(v) == 1
            got = _sample(data) if (hit and data is not None) else None
            await RisingEdge(self.clk)
            if hit:
                return got
            await FallingEdge(self.clk)

    async def write(self, addr, data, strb=0xF):
        await FallingEdge(self.clk)
        self.awaddr.value = addr
        self.awvalid.value = 1
        self.wdata.value = data
        self.wstrb.value = strb
        self.wvalid.value = 1
        self.bready.value = 1
        await self._wait_valid(self.bvalid)
        await FallingEdge(self.clk)
        self.awvalid.value = 0
        self.wvalid.value = 0
        self.bready.value = 0

    async def read(self, addr):
        await FallingEdge(self.clk)
        self.araddr.value = addr
        self.arvalid.value = 1
        self.rready.value = 1
        data = await self._wait_valid(self.rvalid, self.rdata)
        await FallingEdge(self.clk)
        self.arvalid.value = 0
        self.rready.value = 0
        return data
