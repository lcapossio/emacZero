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
//   TX: gmii_txd must hold each byte for exactly 10 (100M) or 100 (10M)
//       clk_125 cycles with gmii_tx_en high for the whole frame, as gmii_cdc's
//       pacer does. The first TXC cycle of each byte sends TXD[3:0], the
//       second TXD[7:4].
//   RX: two RXC cycles are paired into one byte. gmii_rx_dv stays high for
//       the whole frame and gmii_rx_ce strobes once per assembled byte, so a
//       consumer takes a byte only when gmii_rx_dv && gmii_rx_ce. At 1G
//       gmii_rx_ce is always 1.
//
// Clocks:
//   clk_125    - 125 MHz, 0 deg. Clocks TXD and TX_CTL at every speed.
//   clk_125_90 - 125 MHz, 90 deg, from the same source as clk_125. Clocks TXC
//                when 1G is built (RGMII_SPEEDS "ALL" or "1G_ONLY"); unused
//                for "10_100", where TXC runs on clk_125.
//   The 10/100 TXC is a pattern sent through the TXC cell, so no 25 MHz or
//   2.5 MHz clock is needed.
// =============================================================================

module rgmii_if #(
    // Which speeds to synthesize. Logic for unused speeds is tied off so
    // synthesis prunes it. Every value uses the same six TX and five RX DDR
    // cells.
    //   "ALL"     = 10/100/1G (default)
    //   "1G_ONLY" = 1G only (no 10/100 phase counter)
    //   "10_100"  = 10/100 only (TXC on clk_125; clk_125_90 unused)
    parameter RGMII_SPEEDS = "ALL"
)(
    input  wire        clk_125,
    input  wire        clk_125_90,
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

    // RX selects 1G or 10/100 straight from cfg_speed; TX uses synchronized
    // copies (below).
    wire is_1g  = SUPPORT_1G  && ((cfg_speed == 2'b00) || (cfg_speed == 2'b11));

    // =========================================================================
    // TX path
    // =========================================================================
    // One DDR cell per pin. An ODDR (7-series) or ODDRE1 (UltraScale+) has to
    // drive its pad with nothing in between, so the speed select is in front
    // of each cell's d1/d2, never behind its q. TXD and TX_CTL are clocked by
    // clk_125 at every speed, TXC by clk_txc (clk_125_90 when 1G is built,
    // clk_125 otherwise). A cell samples d1 and d2 on the same rising edge and
    // drives d1 in the high half of the next cycle and d2 in the low half.
    //
    // 1G: TXD[3:0] in the high half, TXD[7:4] in the low half; TX_CTL carries
    // TX_EN, then TX_EN ^ TX_ER. TXC is 1/0 on the 90-degree clock, so its
    // edges fall mid-way through each half.
    //
    // 10/100: one TXC period is N clk_125 cycles (N = 5 at 100M, 50 at 10M),
    // or 2N half-cycle slots. TXD and TX_CTL carry the rising-edge value in
    // slots 0..N-1 and the falling-edge value in slots N..2N-1. TXC is high in
    // slots N/2 .. N/2+N-1 (N/2 rounded down), so its rising edge falls inside
    // the first group and its falling edge inside the second, each at least
    // 8 ns from a data change at 100M (10 ns with the 90-degree clock). The
    // nibble is the same in both groups; TX_CTL carries TX_EN, then
    // TX_EN ^ TX_ER.
    localparam SUPPORT_SLOW = SUPPORT_100 || SUPPORT_10;

    wire clk_txc = SUPPORT_1G ? clk_125_90 : clk_125;

    // cfg_speed comes from the system clock domain. Each TX clock domain
    // takes its own synchronized copy, so no timed path runs from the CSR into
    // the cells' inputs. The speed is only changed while the link is down.
    (* ASYNC_REG = "TRUE" *) reg [1:0] spd_t_s1, spd_t_s2;   // clk_125
    (* ASYNC_REG = "TRUE" *) reg [1:0] spd_c_s1, spd_c_s2;   // clk_txc
    always @(posedge clk_125 or negedge rst_n) begin
        if (!rst_n) {spd_t_s2, spd_t_s1} <= 4'd0;
        else        {spd_t_s2, spd_t_s1} <= {spd_t_s1, cfg_speed};
    end
    always @(posedge clk_txc or negedge rst_n) begin
        if (!rst_n) {spd_c_s2, spd_c_s1} <= 4'd0;
        else        {spd_c_s2, spd_c_s1} <= {spd_c_s1, cfg_speed};
    end
    wire t_is_1g  = SUPPORT_1G  && ((spd_t_s2 == 2'b00) || (spd_t_s2 == 2'b11));
    wire t_is_100 = SUPPORT_100 && (spd_t_s2 == 2'b01);
    wire c_is_1g  = SUPPORT_1G  && ((spd_c_s2 == 2'b00) || (spd_c_s2 == 2'b11));
    wire c_is_100 = SUPPORT_100 && (spd_c_s2 == 2'b01);

    // Phase counter, clk_txc domain: tx_ph = 0..N-1 picks slots 2*tx_ph and
    // 2*tx_ph+1. The clk_125 logic below reads it too; with the 90-degree
    // clock that path has 6 ns.
    (* ASYNC_REG = "TRUE" *) reg tx_rst_n_s1, tx_rst_n_s2;
    always @(posedge clk_txc or negedge rst_n) begin
        if (!rst_n) {tx_rst_n_s2, tx_rst_n_s1} <= 2'b00;
        else        {tx_rst_n_s2, tx_rst_n_s1} <= {tx_rst_n_s1, 1'b1};
    end

    wire [5:0] c_last_ph = c_is_100 ? 6'd4 : 6'd49;   // N - 1
    wire [6:0] txc_rise  = c_is_100 ? 7'd2 : 7'd25;   // first high slot
    wire [6:0] txc_fall  = c_is_100 ? 7'd7 : 7'd75;   // first low slot after it
    wire [5:0] t_last_ph = t_is_100 ? 6'd4 : 6'd49;   // N - 1, clk_125 copy
    wire [6:0] tx_n      = t_is_100 ? 7'd5 : 7'd50;   // N

    reg  [5:0] tx_ph;
    wire [6:0] tx_s1 = {tx_ph, 1'b0};                 // slot sent by d1
    wire [6:0] tx_s2 = {tx_ph, 1'b1};                 // slot sent by d2

    always @(posedge clk_txc or negedge tx_rst_n_s2) begin
        if (!tx_rst_n_s2)
            tx_ph <= 6'd0;
        else
            tx_ph <= (tx_ph >= c_last_ph) ? 6'd0 : tx_ph + 6'd1;
    end

    // TXC pattern, registered on clk_txc so the TXC cell is fed by a flop on
    // its own clock.
    reg txc_d1, txc_d2;
    always @(posedge clk_txc) begin
        if (c_is_1g) begin
            txc_d1 <= 1'b1;
            txc_d2 <= 1'b0;
        end else if (SUPPORT_SLOW) begin
            txc_d1 <= (tx_s1 >= txc_rise) && (tx_s1 < txc_fall);
            txc_d2 <= (tx_s2 >= txc_rise) && (tx_s2 < txc_fall);
        end else begin
            txc_d1 <= 1'b0;
            txc_d2 <= 1'b0;
        end
    end

    // 10/100 data, clk_125 domain. A new nibble, TX_EN and TX_ER are taken
    // once per TXC period, on the cycle that registers its last slot pair, so
    // the slot registers use them for the whole next period. tx_hi selects
    // the high nibble in the second period of each byte. It needs no reset:
    // it clears on the first period with gmii_tx_en low, and gmii_tx_en is
    // low whenever the MAC is idle.
    reg [3:0] tx_nib, txd_slow;
    reg       tx_hi, tx_en_q, tx_er_q;
    reg       txctl_slow1, txctl_slow2;

    always @(posedge clk_125) begin
        txd_slow    <= tx_nib;
        txctl_slow1 <= (tx_s1 < tx_n) ? tx_en_q : (tx_en_q ^ tx_er_q);
        txctl_slow2 <= (tx_s2 < tx_n) ? tx_en_q : (tx_en_q ^ tx_er_q);
        if (tx_ph == t_last_ph) begin
            tx_hi   <= gmii_tx_en && !tx_hi;
            tx_nib  <= tx_hi ? gmii_txd[7:4] : gmii_txd[3:0];
            tx_en_q <= gmii_tx_en;
            tx_er_q <= gmii_tx_er;
        end
    end

    // Speed select in front of the cells. At 1G the cells take gmii_txd,
    // gmii_tx_en and gmii_tx_er directly.
    wire [3:0] txd_d1   = t_is_1g      ? gmii_txd[3:0]
                        : SUPPORT_SLOW ? txd_slow : 4'd0;
    wire [3:0] txd_d2   = t_is_1g      ? gmii_txd[7:4]
                        : SUPPORT_SLOW ? txd_slow : 4'd0;
    wire       txctl_d1 = t_is_1g      ? gmii_tx_en
                        : SUPPORT_SLOW ? txctl_slow1 : 1'b0;
    wire       txctl_d2 = t_is_1g      ? (gmii_tx_en ^ gmii_tx_er)
                        : SUPPORT_SLOW ? txctl_slow2 : 1'b0;

    genvar i_tx;
    generate
        for (i_tx = 0; i_tx < 4; i_tx = i_tx + 1) begin : gen_txd
            ddr_output u_txd (
                .clk (clk_125),
                .d1  (txd_d1[i_tx]),
                .d2  (txd_d2[i_tx]),
                .q   (rgmii_txd[i_tx])
            );
        end
    endgenerate

    ddr_output u_tx_ctl (.clk(clk_125), .d1(txctl_d1), .d2(txctl_d2),
                         .q(rgmii_tx_ctl));
    ddr_output u_txc    (.clk(clk_txc), .d1(txc_d1),   .d2(txc_d2),
                         .q(rgmii_txc));

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
    (* ASYNC_REG = "TRUE" *) reg rx_rst_n_s1, rx_rst_n_s2;
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
