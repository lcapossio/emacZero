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
// Clocks:
//   clk_125    - 125 MHz, 0 deg
//   clk_125_90 - 125 MHz, 90 deg
//   clk_25     - 25 MHz (for 100M)
//   clk_2_5    - 2.5 MHz (for 10M)
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
    output wire        gmii_rx_dv,
    output wire        gmii_rx_er
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
    wire tx_ctl_rising  = gmii_tx_en;
    wire tx_ctl_falling = gmii_tx_en ^ gmii_tx_er;

    // At 10/100, RGMII spec sends the same nibble on both DDR halves of TXC.
    wire [3:0] tx_data_rising  = gmii_txd[3:0];
    wire [3:0] tx_data_falling = is_1g ? gmii_txd[7:4] : gmii_txd[3:0];

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
            ddr_output u_tx_ctl (.clk(clk_25), .d1(tx_ctl_rising),
                                 .d2(tx_ctl_falling), .q(txctl_100));
            genvar i_100;
            for (i_100 = 0; i_100 < 4; i_100 = i_100 + 1) begin : gen_d
                ddr_output u_txd (
                    .clk (clk_25),
                    .d1  (tx_data_rising[i_100]),
                    .d2  (tx_data_falling[i_100]),
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
            ddr_output u_tx_ctl (.clk(clk_2_5), .d1(tx_ctl_rising),
                                 .d2(tx_ctl_falling), .q(txctl_10));
            genvar i_10;
            for (i_10 = 0; i_10 < 4; i_10 = i_10 + 1) begin : gen_d
                ddr_output u_txd (
                    .clk (clk_2_5),
                    .d1  (tx_data_rising[i_10]),
                    .d2  (tx_data_falling[i_10]),
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
    reg [3:0] nibble_lo;
    reg       have_lo;
    reg [7:0] rxd_lo_pair;
    reg       rx_dv_lo_pair;
    reg       rx_er_lo_pair;

    always @(posedge rgmii_rxc) begin
        if (!rst_n) begin
            nibble_lo     <= 4'd0;
            have_lo       <= 1'b0;
            rxd_lo_pair   <= 8'd0;
            rx_dv_lo_pair <= 1'b0;
            rx_er_lo_pair <= 1'b0;
        end else if (!is_1g) begin
            rx_dv_lo_pair <= 1'b0;
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
    assign gmii_rx_dv = is_1g ? rx_ctl_rising                     : rx_dv_lo_pair;
    assign gmii_rx_er = is_1g ? (rx_ctl_rising ^ rx_ctl_falling)  : rx_er_lo_pair;

endmodule
