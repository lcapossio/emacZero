// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// rgmii_if.v - RGMII PHY interface (vendor-agnostic), 10/100/1G capable
// Converts between internal 8-bit GMII and 4-bit DDR RGMII.
// Verilog 2001
// =============================================================================
// Speed encoding (cfg_speed[1:0]):
//   2'b00 = 1G (full DDR: rising = TXD[3:0], falling = TXD[7:4])
//   2'b01 = 100M (TXC = 25 MHz, same nibble on both edges)
//   2'b10 = 10M  (TXC = 2.5 MHz, same nibble on both edges)
//   2'b11 = reserved (treated as 1G)
//
// At 10/100 a byte takes two TXC/RXC cycles, low nibble first:
//   TX: gmii_txd must hold each byte for exactly two clk_25 (100M) or clk_2_5
//       (10M) cycles with gmii_tx_en high for the whole frame, as gmii_cdc's
//       pacer does. The first cycle of each byte sends TXD[3:0], the second
//       TXD[7:4].
//   RX: two RXC cycles are paired into one byte. gmii_rx_dv stays high for
//       the whole frame and gmii_rx_ce strobes once per assembled byte, so a
//       consumer takes a byte only when gmii_rx_dv && gmii_rx_ce. At 1G
//       gmii_rx_ce is always 1.
//
// Clocks:
//   clk_125    - 125 MHz, 0 deg
//   clk_125_90 - 125 MHz, 90 deg
//   clk_25     - 25 MHz (for 100M)
//   clk_2_5    - 2.5 MHz (for 10M)
//   clk_25 and clk_2_5 must come from the same source as clk_125 (e.g. the
//   same MMCM), since they sample the clk_125-domain gmii_txd directly.
// =============================================================================

module rgmii_if #(
    // Which speeds to synthesize. Cells for unused speeds are tied off so
    // synthesis prunes them. Reduces resource use when only a subset of
    // speeds is needed on a given board.
    //   "ALL"     = 10/100/1G (default)
    //   "1G_ONLY" = 1G only (saves 8 DDR cells)
    //   "10_100"  = 10/100 only (saves 6 DDR cells)
    parameter RGMII_SPEEDS = "ALL"
)(
    input  wire        clk_125,
    input  wire        clk_125_90,
    input  wire        clk_25,
    input  wire        clk_2_5,
    input  wire        rst_n,

    input  wire [1:0]  cfg_speed,    // 00=1G, 01=100M, 10=10M

    // --- RGMII pins ---
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl,
    output wire        rgmii_txc,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl,
    input  wire        rgmii_rxc,

    // --- Internal GMII (8-bit, single-edge) ---
    input  wire [7:0]  gmii_txd,
    input  wire        gmii_tx_en,
    input  wire        gmii_tx_er,
    output wire [7:0]  gmii_rxd,
    output wire        gmii_rx_dv,     // frame envelope
    output wire        gmii_rx_er,
    output wire        gmii_rx_ce      // byte strobe (1 at 1G)
);

    // =========================================================================
    // Speed decode (with parameter-based pruning)
    // =========================================================================
    localparam SUPPORT_1G  = (RGMII_SPEEDS == "ALL") || (RGMII_SPEEDS == "1G_ONLY");
    localparam SUPPORT_100 = (RGMII_SPEEDS == "ALL") || (RGMII_SPEEDS == "10_100");
    localparam SUPPORT_10  = (RGMII_SPEEDS == "ALL") || (RGMII_SPEEDS == "10_100");

    wire is_1g  = SUPPORT_1G  && ((cfg_speed == 2'b00) || (cfg_speed == 2'b11));
    wire is_100 = SUPPORT_100 && (cfg_speed == 2'b01);
    wire is_10  = SUPPORT_10  && (cfg_speed == 2'b10);

    // =========================================================================
    // TX path
    // =========================================================================
    // 1G: TXD[3:0] on the rising half, TXD[7:4] on the falling half.
    wire tx_ctl_rising  = gmii_tx_en;
    wire tx_ctl_falling = gmii_tx_en ^ gmii_tx_er;

    wire [3:0] tx_data_rising  = gmii_txd[3:0];
    wire [3:0] tx_data_falling = gmii_txd[7:4];

    // 10/100: each byte is held for two TXC cycles; send TXD[3:0] in the first
    // and TXD[7:4] in the second, the same nibble on both halves of each cycle.
    // tx_hi_* counts the cycles of the frame. It needs no reset: it clears on
    // the first cycle with gmii_tx_en low, and gmii_tx_en is low whenever the
    // MAC is idle. The nibble and TX_CTL are registered so they are stable for
    // the whole TXC cycle, whichever edge the DDR cell samples d2 on.
    reg       tx_hi_100, tx_hi_10;
    reg [3:0] txd_100_q, txd_10_q;
    reg       txen_100_q, txer_100_q, txen_10_q, txer_10_q;

    always @(posedge clk_25) begin
        tx_hi_100  <= gmii_tx_en && !tx_hi_100;
        txd_100_q  <= tx_hi_100 ? gmii_txd[7:4] : gmii_txd[3:0];
        txen_100_q <= gmii_tx_en;
        txer_100_q <= gmii_tx_er;
    end

    always @(posedge clk_2_5) begin
        tx_hi_10  <= gmii_tx_en && !tx_hi_10;
        txd_10_q  <= tx_hi_10 ? gmii_txd[7:4] : gmii_txd[3:0];
        txen_10_q <= gmii_tx_en;
        txer_10_q <= gmii_tx_er;
    end

    // Per-speed DDR primitives, gated by support parameters. Output muxed.
    wire txc_1g, txc_100, txc_10;
    wire [3:0] txd_1g, txd_100, txd_10;
    wire       txctl_1g, txctl_100, txctl_10;

    generate
        if (SUPPORT_1G) begin : gen_1g_ddr
            ddr_output u_txc (.clk(clk_125_90), .d1(1'b1), .d2(1'b0), .q(txc_1g));
            ddr_output u_tx_ctl (.clk(clk_125), .d1(tx_ctl_rising),
                                 .d2(tx_ctl_falling), .q(txctl_1g));
            genvar i_1g;
            for (i_1g = 0; i_1g < 4; i_1g = i_1g + 1) begin : gen_d
                ddr_output u_txd (
                    .clk (clk_125),
                    .d1  (tx_data_rising[i_1g]),
                    .d2  (tx_data_falling[i_1g]),
                    .q   (txd_1g[i_1g])
                );
            end
        end else begin : gen_no_1g
            assign txc_1g   = 1'b0;
            assign txd_1g   = 4'd0;
            assign txctl_1g = 1'b0;
        end

        if (SUPPORT_100) begin : gen_100_ddr
            ddr_output u_txc (.clk(clk_25), .d1(1'b1), .d2(1'b0), .q(txc_100));
            ddr_output u_tx_ctl (.clk(clk_25), .d1(txen_100_q),
                                 .d2(txen_100_q ^ txer_100_q), .q(txctl_100));
            genvar i_100;
            for (i_100 = 0; i_100 < 4; i_100 = i_100 + 1) begin : gen_d
                ddr_output u_txd (
                    .clk (clk_25),
                    .d1  (txd_100_q[i_100]),
                    .d2  (txd_100_q[i_100]),
                    .q   (txd_100[i_100])
                );
            end
        end else begin : gen_no_100
            assign txc_100   = 1'b0;
            assign txd_100   = 4'd0;
            assign txctl_100 = 1'b0;
        end

        if (SUPPORT_10) begin : gen_10_ddr
            ddr_output u_txc (.clk(clk_2_5), .d1(1'b1), .d2(1'b0), .q(txc_10));
            ddr_output u_tx_ctl (.clk(clk_2_5), .d1(txen_10_q),
                                 .d2(txen_10_q ^ txer_10_q), .q(txctl_10));
            genvar i_10;
            for (i_10 = 0; i_10 < 4; i_10 = i_10 + 1) begin : gen_d
                ddr_output u_txd (
                    .clk (clk_2_5),
                    .d1  (txd_10_q[i_10]),
                    .d2  (txd_10_q[i_10]),
                    .q   (txd_10[i_10])
                );
            end
        end else begin : gen_no_10
            assign txc_10   = 1'b0;
            assign txd_10   = 4'd0;
            assign txctl_10 = 1'b0;
        end
    endgenerate

    assign rgmii_txc    = is_1g ? txc_1g    : (is_100 ? txc_100    : txc_10);
    assign rgmii_txd    = is_1g ? txd_1g    : (is_100 ? txd_100    : txd_10);
    assign rgmii_tx_ctl = is_1g ? txctl_1g  : (is_100 ? txctl_100  : txctl_10);

    // =========================================================================
    // RX path
    // =========================================================================
    wire [3:0] rxd_rising;
    wire [3:0] rxd_falling;
    wire       rx_ctl_rising;
    wire       rx_ctl_falling;

    genvar i_rx;
    generate
        for (i_rx = 0; i_rx < 4; i_rx = i_rx + 1) begin : gen_rx_data
            ddr_input u_rxd (
                .clk (rgmii_rxc),
                .d   (rgmii_rxd[i_rx]),
                .q1  (rxd_rising[i_rx]),
                .q2  (rxd_falling[i_rx])
            );
        end
    endgenerate

    ddr_input u_rx_ctl (
        .clk (rgmii_rxc),
        .d   (rgmii_rx_ctl),
        .q1  (rx_ctl_rising),
        .q2  (rx_ctl_falling)
    );

    // =========================================================================
    // 10/100 nibble pairing (only used when !is_1g)
    // =========================================================================
    // Synchronize the system reset into the RGMII RX clock domain. rst_n is
    // asynchronous to rgmii_rxc (a PHY-sourced clock); using it directly risks
    // metastable reset release of the pairing state. Async assert, 2-FF sync
    // deassert, matching the gmii_cdc / mii_if reset-synchronizer style.
    reg rx_rst_n_s1, rx_rst_n_s2;
    always @(posedge rgmii_rxc or negedge rst_n) begin
        if (!rst_n) {rx_rst_n_s2, rx_rst_n_s1} <= 2'b00;
        else        {rx_rst_n_s2, rx_rst_n_s1} <= {rx_rst_n_s1, 1'b1};
    end

    // rx_dv_lo_pair strobes once per assembled byte; rx_frame_lo is RX_DV
    // delayed one cycle, so it rises before the first strobe and falls after
    // the last one, giving the consumer an unbroken frame envelope.
    reg [3:0] nibble_lo;
    reg       have_lo;
    reg [7:0] rxd_lo_pair;
    reg       rx_dv_lo_pair;
    reg       rx_er_lo_pair;
    reg       rx_frame_lo;

    always @(posedge rgmii_rxc or negedge rx_rst_n_s2) begin
        if (!rx_rst_n_s2) begin
            nibble_lo     <= 4'd0;
            have_lo       <= 1'b0;
            rxd_lo_pair   <= 8'd0;
            rx_dv_lo_pair <= 1'b0;
            rx_er_lo_pair <= 1'b0;
            rx_frame_lo   <= 1'b0;
        end else if (!is_1g) begin
            rx_dv_lo_pair <= 1'b0;
            rx_frame_lo   <= rx_ctl_rising;
            if (rx_ctl_rising) begin
                if (!have_lo) begin
                    nibble_lo <= rxd_rising;
                    have_lo   <= 1'b1;
                end else begin
                    rxd_lo_pair   <= {rxd_rising, nibble_lo};
                    rx_dv_lo_pair <= 1'b1;
                    rx_er_lo_pair <= rx_ctl_rising ^ rx_ctl_falling;
                    have_lo       <= 1'b0;
                end
            end else begin
                have_lo <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Output: at 1G use direct DDR pair; at 10/100 use the paired latch.
    // The 1G path matches the original byte-for-byte.
    // =========================================================================
    assign gmii_rxd   = is_1g ? {rxd_falling, rxd_rising}         : rxd_lo_pair;
    assign gmii_rx_dv = is_1g ? rx_ctl_rising                     : rx_frame_lo;
    assign gmii_rx_er = is_1g ? (rx_ctl_rising ^ rx_ctl_falling)  : rx_er_lo_pair;
    assign gmii_rx_ce = is_1g ? 1'b1                              : rx_dv_lo_pair;

endmodule
