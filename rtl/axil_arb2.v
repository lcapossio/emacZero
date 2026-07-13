// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// axil_arb2.v - Minimal 2:1 AXI4-Lite arbiter (two masters -> one slave).
//
// Write (AW/W/B) and read (AR/R) channels are arbitrated independently, so a
// read from one master can overlap a write from the other. Within a channel,
// one transaction is in flight at a time: a master is granted when it asserts
// AWVALID (writes) / ARVALID (reads), and holds the grant until the matching
// B / R handshake completes. Fixed priority: master 0 (m0) wins ties.
//
// Grants are registered (one idle cycle of latency before the slave sees the
// request), which keeps the mux purely combinational and avoids AW/AR->grant
// combinational paths. Intended for low-rate CSR access where both masters lead
// a transaction with AWVALID/ARVALID (the emacZero test_sequencer and the
// fcapz EJTAG-AXI bridge both do). Not a general crossbar: single slave, no IDs,
// no outstanding pipelining.
// Verilog 2001
// =============================================================================

module axil_arb2 #(
    parameter AW = 8,     // address width
    parameter DW = 32     // data width
)(
    input  wire            aclk,
    input  wire            aresetn,

    // ---- Master 0 (priority) ----
    input  wire [AW-1:0]   m0_awaddr,
    input  wire            m0_awvalid,
    output wire            m0_awready,
    input  wire [DW-1:0]   m0_wdata,
    input  wire [DW/8-1:0] m0_wstrb,
    input  wire            m0_wvalid,
    output wire            m0_wready,
    output wire [1:0]      m0_bresp,
    output wire            m0_bvalid,
    input  wire            m0_bready,
    input  wire [AW-1:0]   m0_araddr,
    input  wire            m0_arvalid,
    output wire            m0_arready,
    output wire [DW-1:0]   m0_rdata,
    output wire [1:0]      m0_rresp,
    output wire            m0_rvalid,
    input  wire            m0_rready,

    // ---- Master 1 ----
    input  wire [AW-1:0]   m1_awaddr,
    input  wire            m1_awvalid,
    output wire            m1_awready,
    input  wire [DW-1:0]   m1_wdata,
    input  wire [DW/8-1:0] m1_wstrb,
    input  wire            m1_wvalid,
    output wire            m1_wready,
    output wire [1:0]      m1_bresp,
    output wire            m1_bvalid,
    input  wire            m1_bready,
    input  wire [AW-1:0]   m1_araddr,
    input  wire            m1_arvalid,
    output wire            m1_arready,
    output wire [DW-1:0]   m1_rdata,
    output wire [1:0]      m1_rresp,
    output wire            m1_rvalid,
    input  wire            m1_rready,

    // ---- Slave ----
    output wire [AW-1:0]   s_awaddr,
    output wire            s_awvalid,
    input  wire            s_awready,
    output wire [DW-1:0]   s_wdata,
    output wire [DW/8-1:0] s_wstrb,
    output wire            s_wvalid,
    input  wire            s_wready,
    input  wire [1:0]      s_bresp,
    input  wire            s_bvalid,
    output wire            s_bready,
    output wire [AW-1:0]   s_araddr,
    output wire            s_arvalid,
    input  wire            s_arready,
    input  wire [DW-1:0]   s_rdata,
    input  wire [1:0]      s_rresp,
    input  wire            s_rvalid,
    output wire            s_rready
);

    // ---- Write-channel grant (registered) ----
    reg w_busy;
    reg w_sel;      // 0 = m0, 1 = m1
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            w_busy <= 1'b0;
            w_sel  <= 1'b0;
        end else if (!w_busy) begin
            if (m0_awvalid) begin w_sel <= 1'b0; w_busy <= 1'b1; end
            else if (m1_awvalid) begin w_sel <= 1'b1; w_busy <= 1'b1; end
        end else if (s_bvalid && s_bready) begin
            w_busy <= 1'b0;
        end
    end

    wire w_g0 = w_busy && (w_sel == 1'b0);
    wire w_g1 = w_busy && (w_sel == 1'b1);

    // AW / W (mux granted master -> slave)
    assign s_awaddr  = w_g1 ? m1_awaddr : m0_awaddr;
    assign s_awvalid = (w_g0 & m0_awvalid) | (w_g1 & m1_awvalid);
    assign m0_awready = w_g0 & s_awready;
    assign m1_awready = w_g1 & s_awready;

    assign s_wdata  = w_g1 ? m1_wdata : m0_wdata;
    assign s_wstrb  = w_g1 ? m1_wstrb : m0_wstrb;
    assign s_wvalid = (w_g0 & m0_wvalid) | (w_g1 & m1_wvalid);
    assign m0_wready = w_g0 & s_wready;
    assign m1_wready = w_g1 & s_wready;

    // B (slave -> granted master)
    assign s_bready  = (w_g0 & m0_bready) | (w_g1 & m1_bready);
    assign m0_bvalid = w_g0 & s_bvalid;
    assign m1_bvalid = w_g1 & s_bvalid;
    assign m0_bresp  = s_bresp;
    assign m1_bresp  = s_bresp;

    // ---- Read-channel grant (registered) ----
    reg r_busy;
    reg r_sel;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            r_busy <= 1'b0;
            r_sel  <= 1'b0;
        end else if (!r_busy) begin
            if (m0_arvalid) begin r_sel <= 1'b0; r_busy <= 1'b1; end
            else if (m1_arvalid) begin r_sel <= 1'b1; r_busy <= 1'b1; end
        end else if (s_rvalid && s_rready) begin
            r_busy <= 1'b0;
        end
    end

    wire r_g0 = r_busy && (r_sel == 1'b0);
    wire r_g1 = r_busy && (r_sel == 1'b1);

    // AR (mux granted master -> slave)
    assign s_araddr  = r_g1 ? m1_araddr : m0_araddr;
    assign s_arvalid = (r_g0 & m0_arvalid) | (r_g1 & m1_arvalid);
    assign m0_arready = r_g0 & s_arready;
    assign m1_arready = r_g1 & s_arready;

    // R (slave -> granted master)
    assign s_rready  = (r_g0 & m0_rready) | (r_g1 & m1_rready);
    assign m0_rvalid = r_g0 & s_rvalid;
    assign m1_rvalid = r_g1 & s_rvalid;
    assign m0_rdata  = s_rdata;
    assign m1_rdata  = s_rdata;
    assign m0_rresp  = s_rresp;
    assign m1_rresp  = s_rresp;

endmodule
