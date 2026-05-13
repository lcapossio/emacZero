// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_stats.v - Ethernet MAC statistics counters
// 32-bit saturating counters for TX/RX frame, byte, and error counts plus the
// detailed RX breakdown (size buckets, error type, bcast/mcast).
// All inputs and outputs are in the system clock domain.
// Verilog 2001
// =============================================================================

module eth_stats (
    input  wire        clk,
    input  wire        rst_n,

    // ---- GMII observation (sys_clk domain) ----
    input  wire        gmii_tx_en,     // high while TX byte on wire
    input  wire        gmii_rx_dv,     // high while RX byte on wire

    // ---- Frame completion pulses (single-cycle, sys_clk domain) ----
    input  wire        tx_frame_done,  // falling edge of gmii_tx_en
    input  wire        rx_frame_good,  // m_axis_tlast && tvalid && !terror
    input  wire        rx_frame_bad,   // m_axis_tlast && tvalid && terror

    // ---- RX classification bus (single-cycle, end-of-frame) ----
    input  wire        rx_stat_done,   // pulses when a delivered frame ends
    input  wire [13:0] rx_stat_len,    // total wire bytes (incl FCS)
    input  wire        rx_stat_err_fcs,
    input  wire        rx_stat_err_align,
    input  wire        rx_stat_err_overflow,
    input  wire        rx_stat_err_oversize,
    input  wire        rx_stat_is_bcast,
    input  wire        rx_stat_is_mcast,

    // ---- Counter outputs ----
    output reg  [31:0] tx_frame_cnt,
    output reg  [31:0] tx_byte_cnt,
    output reg  [31:0] rx_frame_cnt,
    output reg  [31:0] rx_byte_cnt,
    output reg  [31:0] rx_crc_err_cnt,        // legacy alias = rx_err_fcs_cnt

    // RX error breakdown
    output reg  [31:0] rx_err_align_cnt,
    output reg  [31:0] rx_err_overflow_cnt,
    output reg  [31:0] rx_err_oversize_cnt,

    // RX bcast/mcast
    output reg  [31:0] rx_bcast_cnt,
    output reg  [31:0] rx_mcast_cnt,

    // RX size buckets (by total wire bytes incl. FCS)
    output reg  [31:0] rx_size_64_cnt,        // ==64
    output reg  [31:0] rx_size_65_127_cnt,
    output reg  [31:0] rx_size_128_255_cnt,
    output reg  [31:0] rx_size_256_511_cnt,
    output reg  [31:0] rx_size_512_1023_cnt,
    output reg  [31:0] rx_size_1024_1518_cnt,
    output reg  [31:0] rx_size_jumbo_cnt,     // >1518

    // ---- Clear (active-high pulse) ----
    input  wire        clr_tx,
    input  wire        clr_rx
);

    // Saturating increment: returns current value + 1, or holds at max
    `define SAT_INC(cnt) ((cnt) == 32'hFFFFFFFF ? 32'hFFFFFFFF : (cnt) + 32'd1)

    // =====================================================================
    // TX counters
    // =====================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_frame_cnt <= 32'd0;
            tx_byte_cnt  <= 32'd0;
        end else if (clr_tx) begin
            tx_frame_cnt <= 32'd0;
            tx_byte_cnt  <= 32'd0;
        end else begin
            if (tx_frame_done)
                tx_frame_cnt <= `SAT_INC(tx_frame_cnt);

            if (gmii_tx_en)
                tx_byte_cnt <= `SAT_INC(tx_byte_cnt);
        end
    end

    // =====================================================================
    // RX counters - basic
    // =====================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_frame_cnt   <= 32'd0;
            rx_byte_cnt    <= 32'd0;
            rx_crc_err_cnt <= 32'd0;
        end else if (clr_rx) begin
            rx_frame_cnt   <= 32'd0;
            rx_byte_cnt    <= 32'd0;
            rx_crc_err_cnt <= 32'd0;
        end else begin
            if (rx_frame_good || rx_frame_bad)
                rx_frame_cnt <= `SAT_INC(rx_frame_cnt);

            if (gmii_rx_dv)
                rx_byte_cnt <= `SAT_INC(rx_byte_cnt);

            if (rx_frame_bad)
                rx_crc_err_cnt <= `SAT_INC(rx_crc_err_cnt);
        end
    end

    // =====================================================================
    // RX counters - error breakdown + bcast/mcast + size buckets
    // Driven from end-of-frame classification pulse.
    // =====================================================================
    wire bucket_64        = (rx_stat_len == 14'd64);
    wire bucket_65_127    = (rx_stat_len >  14'd64)   && (rx_stat_len <= 14'd127);
    wire bucket_128_255   = (rx_stat_len >  14'd127)  && (rx_stat_len <= 14'd255);
    wire bucket_256_511   = (rx_stat_len >  14'd255)  && (rx_stat_len <= 14'd511);
    wire bucket_512_1023  = (rx_stat_len >  14'd511)  && (rx_stat_len <= 14'd1023);
    wire bucket_1024_1518 = (rx_stat_len >  14'd1023) && (rx_stat_len <= 14'd1518);
    wire bucket_jumbo     = (rx_stat_len >  14'd1518);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_err_align_cnt      <= 32'd0;
            rx_err_overflow_cnt   <= 32'd0;
            rx_err_oversize_cnt   <= 32'd0;
            rx_bcast_cnt          <= 32'd0;
            rx_mcast_cnt          <= 32'd0;
            rx_size_64_cnt        <= 32'd0;
            rx_size_65_127_cnt    <= 32'd0;
            rx_size_128_255_cnt   <= 32'd0;
            rx_size_256_511_cnt   <= 32'd0;
            rx_size_512_1023_cnt  <= 32'd0;
            rx_size_1024_1518_cnt <= 32'd0;
            rx_size_jumbo_cnt     <= 32'd0;
        end else if (clr_rx) begin
            rx_err_align_cnt      <= 32'd0;
            rx_err_overflow_cnt   <= 32'd0;
            rx_err_oversize_cnt   <= 32'd0;
            rx_bcast_cnt          <= 32'd0;
            rx_mcast_cnt          <= 32'd0;
            rx_size_64_cnt        <= 32'd0;
            rx_size_65_127_cnt    <= 32'd0;
            rx_size_128_255_cnt   <= 32'd0;
            rx_size_256_511_cnt   <= 32'd0;
            rx_size_512_1023_cnt  <= 32'd0;
            rx_size_1024_1518_cnt <= 32'd0;
            rx_size_jumbo_cnt     <= 32'd0;
        end else if (rx_stat_done) begin
            if (rx_stat_err_align)    rx_err_align_cnt    <= `SAT_INC(rx_err_align_cnt);
            if (rx_stat_err_overflow) rx_err_overflow_cnt <= `SAT_INC(rx_err_overflow_cnt);
            if (rx_stat_err_oversize) rx_err_oversize_cnt <= `SAT_INC(rx_err_oversize_cnt);
            if (rx_stat_is_bcast)     rx_bcast_cnt        <= `SAT_INC(rx_bcast_cnt);
            if (rx_stat_is_mcast)     rx_mcast_cnt        <= `SAT_INC(rx_mcast_cnt);

            if (bucket_64)        rx_size_64_cnt        <= `SAT_INC(rx_size_64_cnt);
            if (bucket_65_127)    rx_size_65_127_cnt    <= `SAT_INC(rx_size_65_127_cnt);
            if (bucket_128_255)   rx_size_128_255_cnt   <= `SAT_INC(rx_size_128_255_cnt);
            if (bucket_256_511)   rx_size_256_511_cnt   <= `SAT_INC(rx_size_256_511_cnt);
            if (bucket_512_1023)  rx_size_512_1023_cnt  <= `SAT_INC(rx_size_512_1023_cnt);
            if (bucket_1024_1518) rx_size_1024_1518_cnt <= `SAT_INC(rx_size_1024_1518_cnt);
            if (bucket_jumbo)     rx_size_jumbo_cnt     <= `SAT_INC(rx_size_jumbo_cnt);
        end
    end

    `undef SAT_INC

endmodule
