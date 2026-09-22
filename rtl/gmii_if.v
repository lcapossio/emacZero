// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// gmii_if.v - GMII PHY interface (vendor-agnostic), 1000 Mbps
// Registers the internal 8-bit GMII bus onto the GMII pins and forwards
// GTX_CLK to the PHY.
// Verilog 2001
// =============================================================================
// GMII is a 1000 Mbps-only interface: 8 bits per clock at 125 MHz. A tri-speed
// PHY that exposes GMII reverts to 4-bit MII at 10/100, where the PHY - not the
// MAC - sources TX_CLK. That pin-sharing mode is a different interface and is
// NOT implemented here; instantiate PHY_INTERFACE="MII" for 10/100 operation.
// Accordingly this module has no cfg_speed input and always runs at 125 MHz.
//
// Clocks:
//   clk_125    - 125 MHz, 0 deg. TX data is launched on this edge, and GTX_CLK
//                is forwarded from it INVERTED (see below).
//   gmii_rx_clk- 125 MHz RX clock sourced by the PHY.
//
// GTX_CLK phase. IEEE 802.3 Clause 35.5.2 requires 2.5 ns setup / 0.5 ns hold
// AT THE SIGNAL SOURCE - i.e. at this MAC's own output pins, which is what this
// module controls - against an 8 ns data window. Those relax to 2.0 ns / 0 ns
// at the receiver (the PHY pins); the 500 ps difference is the board
// length-matching budget. The forwarded clock's RISING edge must therefore sit
// near the centre of the data window, not near its start:
//
//   clk_125    __|""""|____|""""|____   data launches on each rising edge
//   TXD        XXXX<   byte N    >XXXX
//   GTX_CLK    ""|____|""""|____|""""   PHY samples on GTX_CLK rising
//                       ^ 4 ns into the data window
//
// Driving the DDR cell from clk_125 with d1=0/d2=1 puts GTX_CLK's rising edge
// at clk_125's FALLING edge - 4 ns after the data transition - leaving ~4 ns
// each of setup and hold before board and clock-to-out skew. A dedicated 180
// deg clock is equivalent.
//
// Do NOT forward clk_125_90 here: that is the RGMII convention (where the
// ~2 ns offset satisfies RGMII's own internal-delay requirement), and 2 ns is
// below the 2.5 ns setup GMII requires at the source, before any skew is
// subtracted. Likewise do not forward clk_125 with d1=1/d2=0: that is
// edge-aligned and leaves no deliberate phase margin in either direction.
//
// GTX_CLK duty cycle: Clause 35 allows 35%-75%. The inverted DDR waveform is
// 50% by construction, so it is compliant with margin.
//
// I/O packing: the TX output and RX input registers below are written as plain
// single-stage flops so the tool can pack them into the IOB. Constrain with
// `set_property IOB TRUE` in the XDC; no attribute is applied here so the RTL
// stays vendor-neutral.
// =============================================================================

module gmii_if (
    input  wire        clk_125,
    input  wire        rst_n,

    // --- GMII pins (to/from PHY) ---
    output reg  [7:0]  gmii_txd,
    output reg         gmii_tx_en,
    output reg         gmii_tx_er,
    output wire        gmii_gtx_clk,
    input  wire        gmii_rx_clk,
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_dv,
    input  wire        gmii_rx_er,

    // --- Internal GMII, media-clock domain (to/from gmii_cdc) ---
    input  wire [7:0]  gmii_txd_int,
    input  wire        gmii_tx_en_int,
    input  wire        gmii_tx_er_int,
    output reg  [7:0]  gmii_rxd_int,
    output reg         gmii_rx_dv_int,
    output reg         gmii_rx_er_int
);

    // =========================================================================
    // TX path: clk_125 -> pins
    // =========================================================================
    // rst_n is generated in the system-clock domain and is asynchronous to
    // clk_125. Async assert, 2-FF sync deassert, so the TX output registers
    // cannot release inconsistently and emit a spurious TX_EN/TX_ER pulse.
    (* ASYNC_REG = "TRUE" *) reg tx_rst_n_s1, tx_rst_n_s2;
    always @(posedge clk_125 or negedge rst_n) begin
        if (!rst_n) {tx_rst_n_s2, tx_rst_n_s1} <= 2'b00;
        else        {tx_rst_n_s2, tx_rst_n_s1} <= {tx_rst_n_s1, 1'b1};
    end

    // gmii_cdc already presents its media-side output registered on clk_125,
    // so this is a single IOB-bound retiming stage, not a resynchronizer.
    always @(posedge clk_125 or negedge tx_rst_n_s2) begin
        if (!tx_rst_n_s2) begin
            gmii_txd   <= 8'd0;
            gmii_tx_en <= 1'b0;
            gmii_tx_er <= 1'b0;
        end else begin
            gmii_txd   <= gmii_txd_int;
            gmii_tx_en <= gmii_tx_en_int;
            gmii_tx_er <= gmii_tx_er_int;
        end
    end

    // GTX_CLK forwarding. Driving the clock out of a DDR cell (rather than
    // routing a clock to a pin directly) keeps it on the clock network to the
    // IOB. d1=0/d2=1 inverts the waveform so the rising edge lands mid-window;
    // see the phase discussion in the header.
    ddr_output u_gtx_clk (
        .clk (clk_125),
        .d1  (1'b0),
        .d2  (1'b1),
        .q   (gmii_gtx_clk)
    );

    // =========================================================================
    // RX path: pins -> gmii_rx_clk
    // =========================================================================
    // rst_n is asynchronous to gmii_rx_clk (a PHY-sourced clock). Async assert,
    // 2-FF sync deassert, matching the rgmii_if / gmii_cdc reset style.
    (* ASYNC_REG = "TRUE" *) reg rx_rst_n_s1, rx_rst_n_s2;
    always @(posedge gmii_rx_clk or negedge rst_n) begin
        if (!rst_n) {rx_rst_n_s2, rx_rst_n_s1} <= 2'b00;
        else        {rx_rst_n_s2, rx_rst_n_s1} <= {rx_rst_n_s1, 1'b1};
    end

    always @(posedge gmii_rx_clk or negedge rx_rst_n_s2) begin
        if (!rx_rst_n_s2) begin
            gmii_rxd_int   <= 8'd0;
            gmii_rx_dv_int <= 1'b0;
            gmii_rx_er_int <= 1'b0;
        end else begin
            gmii_rxd_int   <= gmii_rxd;
            gmii_rx_dv_int <= gmii_rx_dv;
            gmii_rx_er_int <= gmii_rx_er;
        end
    end

endmodule
