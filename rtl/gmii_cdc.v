// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// gmii_cdc.v - GMII Clock Domain Crossing Bridge (for RGMII/Gigabit)
// Store-and-forward CDC between system clock and media clock domains.
// No nibble conversion — both sides are 8-bit GMII.
//
// TX carries two streams, each through its own FIFO: data frames
// (gmii_txd_in) and MAC Control frames (gmii_ctl_txd_in, e.g. PAUSE). The
// media side picks the next frame to send: a control frame first, else a data
// frame unless tx_hold is set. A data frame chosen but still in its start gap
// gives way when a control frame arrives or tx_hold rises, so tx_hold stops
// data frames at the media side, not just as they enter the FIFO. A frame
// that has started is always sent whole.
// Verilog 2001
// =============================================================================

module gmii_cdc #(
    // Largest frame the RX path must deliver intact (DA..FCS bytes). The RX CDC
    // FIFO is store-and-forward - the sys side waits for a frame's EOF marker -
    // so it must hold MAX_FRAME + 8 preamble/SFD words + the EOF word + the
    // slots held back for that EOF. 4096-word floor keeps standard-MTU builds
    // at their previous depth for small-frame bursts.
    parameter MAX_FRAME          = 9018,
    parameter RX_FIFO_ADDR_WIDTH = ($clog2(MAX_FRAME + 10) > 12) ?
                                    $clog2(MAX_FRAME + 10) : 12,
    // Storage for both CDC FIFOs (async_fifo RAM_STYLE). "BLOCK" maps them to
    // block RAM; "DISTRIBUTED" to LUTRAM, which at the 16K-word jumbo depths
    // costs ~7K LUTs and does not close timing at 100/125 MHz on Artix-7.
    parameter FIFO_RAM_STYLE     = "BLOCK"
)(
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    input  wire        media_clk,      // 125 MHz TX/media clock
    input  wire        media_rx_clk,   // RGMII RX clock or media_clk for GMII loopback

    // Speed selection (sys_clk domain; sampled into media_clk via 2-FF sync)
    input  wire [1:0]  cfg_speed,      // 00=1G, 01=100M, 10=10M

    // ---- GMII from MAC (sys_clk domain) ----
    input  wire [7:0]  gmii_txd_in,
    input  wire        gmii_tx_en_in,
    input  wire        gmii_tx_er_in,

    // ---- GMII control frames from MAC (sys_clk domain) ----
    // Frames of at most 72 bytes (preamble to FCS); start one only while
    // tx_ctl_busy is low. Tie gmii_ctl_tx_en_in low when unused.
    input  wire [7:0]  gmii_ctl_txd_in,
    input  wire        gmii_ctl_tx_en_in,
    input  wire        gmii_ctl_tx_er_in,

    // 1 = start no new data frame on the media side (sys_clk domain, e.g. a
    // received PAUSE). Control frames are not held.
    input  wire        tx_hold,

    // ---- GMII to MAC (sys_clk domain) ----
    output reg  [7:0]  gmii_rxd_out,
    output reg         gmii_rx_dv_out,
    output reg         gmii_rx_er_out,

    // ---- GMII to media interface (media_clk domain) ----
    output reg  [7:0]  gmii_txd_out,
    output reg         gmii_tx_en_out,
    output reg         gmii_tx_er_out,

    // ---- GMII from media interface (media_clk domain) ----
    input  wire [7:0]  gmii_rxd_in,
    input  wire        gmii_rx_dv_in,  // frame envelope
    input  wire        gmii_rx_er_in,
    input  wire        gmii_rx_ce_in,  // byte strobe; tie 1 when every dv cycle is a byte

    // ---- Status ----
    output wire        tx_busy,
    output wire        tx_ctl_busy,    // control FIFO cannot take a whole frame
    output wire [11:0] tx_fifo_level
);

    // =========================================================================
    // Reset synchronizers
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg media_rst_n_s1, media_rst_n_s2;
    (* ASYNC_REG = "TRUE" *) reg media_rx_rst_n_s1, media_rx_rst_n_s2;
    always @(posedge media_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) {media_rst_n_s2, media_rst_n_s1} <= 2'b00;
        else            {media_rst_n_s2, media_rst_n_s1} <= {media_rst_n_s1, 1'b1};
    end
    always @(posedge media_rx_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) {media_rx_rst_n_s2, media_rx_rst_n_s1} <= 2'b00;
        else            {media_rx_rst_n_s2, media_rx_rst_n_s1} <= {media_rx_rst_n_s1, 1'b1};
    end

    // =========================================================================
    // RX path: media_clk GMII -> async FIFO -> sys_clk GMII
    // =========================================================================
    // FIFO data: [9] = EOF marker, [8] = error, [7:0] = data.
    // On an EOF word, [8] set means the frame was truncated by RX FIFO overflow.
    localparam [RX_FIFO_ADDR_WIDTH:0] RX_FIFO_DEPTH = 1 << RX_FIFO_ADDR_WIDTH;
    reg [9:0]  rx_wr_data;
    reg        rx_wr_en;
    wire       rx_wr_full;
    wire [RX_FIFO_ADDR_WIDTH:0] rx_wr_count;
    reg        rx_dv_d1;
    reg        rx_drop;         // media_rx: current frame lost bytes to overflow

    // Overflow policy. Data words are only written while slots are held back
    // for the frame's EOF word, so it always fits: a dropped EOF would leave
    // the sys side reading two frames as one (the frame toggle still fires).
    // Once a data word is refused, the rest of that frame is dropped too - no
    // holes - and its EOF carries the truncation flag. rx_wr_count lags reads,
    // never writes, so it only ever over-reports occupancy (safe direction).
    //
    // rx_data_room is registered to keep the pointer arithmetic out of the
    // FIFO write-enable path (unregistered it failed 125 MHz timing). The
    // registered value misses at most the one write accepted since it was
    // sampled, so the threshold is DEPTH-2: sampled <= DEPTH-3 means at most
    // DEPTH-1 words after this write, leaving the EOF its slot.
    wire rx_wr_is_eof   = rx_wr_data[9];
    reg  rx_data_room;
    always @(posedge media_rx_clk or negedge media_rx_rst_n_s2) begin
        if (!media_rx_rst_n_s2)
            rx_data_room <= 1'b1;
        else
            rx_data_room <= (rx_wr_count < RX_FIFO_DEPTH - 2'd2);
    end
    wire rx_wr_accept   = rx_wr_en &&
                          (rx_wr_is_eof ? !rx_wr_full : (rx_data_room && !rx_drop));
    wire rx_data_refuse = rx_wr_en && !rx_wr_is_eof && !rx_wr_accept;
    wire [9:0] rx_fifo_din = rx_wr_is_eof ? {1'b1, rx_drop | rx_data_refuse, 8'h00}
                                          : rx_wr_data;

    always @(posedge media_rx_clk or negedge media_rx_rst_n_s2) begin
        if (!media_rx_rst_n_s2) begin
            rx_wr_data <= 10'd0;
            rx_wr_en   <= 1'b0;
            rx_dv_d1   <= 1'b0;
            rx_drop    <= 1'b0;
        end else begin
            rx_wr_en <= 1'b0;
            rx_dv_d1 <= gmii_rx_dv_in;

            if (rx_wr_en && rx_wr_is_eof)
                rx_drop <= 1'b0;
            else if (rx_data_refuse)
                rx_drop <= 1'b1;

            // A frame is the gmii_rx_dv_in envelope; within it only cycles
            // with gmii_rx_ce_in carry a byte (rgmii_if at 10/100 assembles
            // one byte every two RXC cycles).
            if (gmii_rx_dv_in) begin
                if (gmii_rx_ce_in) begin
                    rx_wr_data <= {1'b0, gmii_rx_er_in, gmii_rxd_in};
                    rx_wr_en   <= 1'b1;
                end
            end else if (rx_dv_d1) begin
                // Write EOF marker
                rx_wr_data <= {1'b1, 1'b0, 8'h00};
                rx_wr_en   <= 1'b1;
            end
        end
    end

    // Frame toggle for CDC handoff
    reg rx_frame_toggle;
    always @(posedge media_rx_clk or negedge media_rx_rst_n_s2) begin
        if (!media_rx_rst_n_s2)
            rx_frame_toggle <= 1'b0;
        else if (rx_wr_accept && rx_wr_is_eof)
            rx_frame_toggle <= ~rx_frame_toggle;
    end

    // RX async FIFO
    wire [9:0] rx_rd_data;
    wire       rx_rd_empty;
    reg        rx_rd_en;

    async_fifo #(.DATA_WIDTH(10), .ADDR_WIDTH(RX_FIFO_ADDR_WIDTH),
                 .RAM_STYLE(FIFO_RAM_STYLE)) u_rx_fifo (
        .wr_clk  (media_rx_clk),
        .wr_rst_n(media_rx_rst_n_s2),
        .wr_data (rx_fifo_din),
        .wr_en   (rx_wr_accept),
        .wr_full (rx_wr_full),
        .rd_clk  (sys_clk),
        .rd_rst_n(sys_rst_n),
        .rd_data (rx_rd_data),
        .rd_en   (rx_rd_en),
        .rd_empty(rx_rd_empty),
        .wr_data_count(rx_wr_count)
    );

    // Frame availability tracking (sys_clk domain)
    (* ASYNC_REG = "TRUE" *) reg rx_toggle_s1, rx_toggle_s2, rx_toggle_s3;
    reg [7:0]  rx_avail_delay;
    // Width = RX FIFO addr width + 1 (RX_CNT_W). A 4-bit counter aliased once 16
    // frames buffered: under sustained line rate the 125 MHz media_rx side fills
    // faster than the (slower) sys side drains, so small frames pile up well past
    // 16 long before the RX FIFO fills - the counter wrapped, rx_frame_ready
    // read false, and the readout stalled. At ADDR_WIDTH+1 bits the FIFO fills
    // first, so it cannot alias.
    localparam RX_CNT_W = RX_FIFO_ADDR_WIDTH + 1;
    reg [RX_CNT_W-1:0] rx_frames_pending;
    reg        rx_frame_done_pulse;
    reg        rx_reading;
    // One-byte hold: each data word waits here until the next word is seen, so
    // an overflow-truncated frame can flag its own last byte with rx_er rather
    // than growing an extra error byte (which inflated RX byte and size stats).
    reg  [7:0] rx_pend_data;
    reg        rx_pend_er;
    reg        rx_pend_valid;

    wire rx_frame_avail   = (rx_toggle_s2 != rx_toggle_s3);
    wire rx_frame_avail_d = rx_avail_delay[7];
    // rx_frames_pending lags a retired frame by one cycle (done pulse in
    // flight), and at an EOF still counts the frame being retired. Readiness
    // must exclude both, or the reader starts a frame whose EOF has not been
    // written yet - cut-through, which underflows at 10/100 and breaks framing.
    wire [RX_CNT_W-1:0] rx_done_inflight = {{(RX_CNT_W-1){1'b0}}, rx_frame_done_pulse};
    wire rx_frame_ready   = (rx_frames_pending > rx_done_inflight);
    wire rx_next_ready    = (rx_frames_pending > rx_done_inflight + 1'b1);

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rx_toggle_s1    <= 1'b0;
            rx_toggle_s2    <= 1'b0;
            rx_toggle_s3    <= 1'b0;
            rx_avail_delay  <= 8'd0;
            rx_frames_pending <= {RX_CNT_W{1'b0}};
        end else begin
            rx_toggle_s1 <= rx_frame_toggle;
            rx_toggle_s2 <= rx_toggle_s1;
            rx_toggle_s3 <= rx_toggle_s2;
            rx_avail_delay <= {rx_avail_delay[6:0], rx_frame_avail};

            case ({rx_frame_avail_d, rx_frame_done_pulse})
                2'b10: rx_frames_pending <= rx_frames_pending + 1'b1;
                2'b01: if (rx_frames_pending != {RX_CNT_W{1'b0}})
                           rx_frames_pending <= rx_frames_pending - 1'b1;
                default: ;
            endcase
        end
    end

    // RX readout state machine (sys_clk domain)
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            gmii_rxd_out        <= 8'd0;
            gmii_rx_dv_out      <= 1'b0;
            gmii_rx_er_out      <= 1'b0;
            rx_rd_en            <= 1'b0;
            rx_reading          <= 1'b0;
            rx_frame_done_pulse <= 1'b0;
            rx_pend_data        <= 8'd0;
            rx_pend_er          <= 1'b0;
            rx_pend_valid       <= 1'b0;
        end else begin
            rx_rd_en            <= 1'b0;
            gmii_rx_dv_out      <= 1'b0;
            gmii_rx_er_out      <= 1'b0;
            rx_frame_done_pulse <= 1'b0;

            if (rx_reading) begin
                if (!rx_rd_empty) begin
                    if (rx_rd_data[9]) begin
                        // EOF marker: end this frame (consumed, not output).
                        // Release the held last byte; if the frame was truncated
                        // by overflow (EOF err bit) it carries rx_er, so the MAC
                        // terrors the frame without an extra byte. A frame
                        // dropped whole has no held byte and emits nothing.
                        rx_frame_done_pulse <= 1'b1;
                        if (rx_pend_valid) begin
                            gmii_rxd_out   <= rx_pend_data;
                            gmii_rx_dv_out <= 1'b1;
                            gmii_rx_er_out <= rx_pend_er | rx_rd_data[8];
                        end
                        rx_pend_valid <= 1'b0;
                        if (rx_next_ready) begin
                            // Next frame is already whole in the FIFO: keep the
                            // read stream going. Its first word goes into the
                            // hold next cycle, which is the dv-low gap.
                            rx_rd_en <= 1'b1;
                        end else begin
                            // Nothing complete behind this frame: go idle WITHOUT
                            // a speculative pop. That pop used to eat the next
                            // word - a preamble byte of a partly written frame,
                            // or the EOF of a frame dropped whole by overflow,
                            // which then left rx_frames_pending stuck.
                            rx_reading <= 1'b0;
                        end
                    end else begin
                        if (rx_pend_valid) begin
                            gmii_rxd_out   <= rx_pend_data;
                            gmii_rx_dv_out <= 1'b1;
                            gmii_rx_er_out <= rx_pend_er;
                        end
                        rx_pend_data  <= rx_rd_data[7:0];
                        rx_pend_er    <= rx_rd_data[8];
                        rx_pend_valid <= 1'b1;
                        rx_rd_en      <= 1'b1;
                    end
                end else if (!rx_frame_ready) begin
                    rx_reading <= 1'b0;
                end
            end else if (rx_frame_ready && !rx_rd_empty) begin
                // Start a buffered frame. rd_en runs one cycle ahead of the
                // reader: this pop lands on the edge where the reading path
                // first sees the word, so each word is consumed exactly once.
                rx_reading <= 1'b1;
                rx_rd_en   <= 1'b1;
            end
        end
    end

    // =========================================================================
    // TX path: sys_clk GMII -> packet FIFO (data + EOF sideband) -> media_clk GMII
    // Store-and-forward: the media side does not start a frame until that frame's
    // EOF byte has been committed to the FIFO, tracked by a gray-coded committed-
    // frame counter. This mirrors the RX path's EOF-marker packet FIFO (and the
    // MII adapter's scheme), replacing the separate length FIFO the earlier
    // revision used to signal frame boundaries.
    // =========================================================================
    // One-cycle delay so the EOF sideband bit can be attached to the frame's
    // last byte: tx_en_fall pulses the cycle after gmii_tx_en_in drops, which is
    // exactly when tx_data_d1 still holds that last byte.
    reg        tx_en_d1;
    reg  [7:0] tx_data_d1;
    reg        tx_er_d1;
    reg        tx_valid_d1;
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tx_en_d1    <= 1'b0;
            tx_data_d1  <= 8'd0;
            tx_er_d1    <= 1'b0;
            tx_valid_d1 <= 1'b0;
        end else begin
            tx_en_d1    <= gmii_tx_en_in;
            tx_data_d1  <= gmii_txd_in;
            tx_er_d1    <= gmii_tx_er_in;   // rides with its byte through the FIFO
            tx_valid_d1 <= gmii_tx_en_in;
        end
    end
    wire tx_en_fall = tx_en_d1 && !gmii_tx_en_in;

    // FIFO word: [9] = error (per byte), [8] = EOF (set on the frame's last byte),
    // [7:0] = data. The error bit carries gmii_tx_er_in across the CDC so the
    // media side can re-drive gmii_tx_er_out, mirroring the RX rx_er path.
    wire [9:0] tx_wr_data   = {tx_er_d1, tx_en_fall, tx_data_d1};
    wire       tx_wr_en     = tx_valid_d1;
    wire       tx_wr_full;
    wire       tx_wr_accept = tx_wr_en && !tx_wr_full;
    wire       tx_eof_wr    = tx_wr_accept && tx_wr_data[8];

    wire [9:0] txd_rd_data;     // data FIFO head
    wire       txd_rd_empty;
    wire       txd_rd_en;
    reg        tx_rd_en;        // pop the selected FIFO (tx_sel_ctl)

    // FIFO occupancy (sys_clk / write domain), taken directly from the async
    // FIFO's exact write-side data count (wr_ptr - synced rd_ptr).
    wire [14:0] tx_fifo_count;

    // A frame takes MAX_FRAME (at least the 9018-byte jumbo frame) plus 12
    // preamble / SFD / FCS words in the FIFO, and one more may still be in the
    // tx_*_d1 stage when tx_busy is sampled. With tx_hold the media side can
    // stop reading, so a frame started at TX_START_LIMIT must still fit.
    localparam [14:0] TX_FIFO_DEPTH      = 15'd16383;
    localparam [14:0] TX_MAX_FRAME_BYTES = (MAX_FRAME > 9018) ? MAX_FRAME : 15'd9018;
    localparam [14:0] TX_START_LIMIT     = TX_FIFO_DEPTH - TX_MAX_FRAME_BYTES - 15'd13;

    // So MAX_FRAME + 13 words must fit in the 16K-word TX FIFO: MAX_FRAME at
    // most 16370 (above that TX_START_LIMIT wraps and tx_busy never rises).
    // Verilog-2001 has no elaboration-time $error, so an unsupported value
    // instantiates a module that does not exist; its name is the error message.
    generate
        if (MAX_FRAME > 16370) begin : gen_max_frame_check
            EMACZERO_CONFIG_ERROR_gmii_cdc_MAX_FRAME_must_be_at_most_16370
                u_max_frame_too_large ();
        end
    endgenerate

    // Committed-frame counter (sys_clk): increments when a frame's EOF byte is
    // accepted, i.e. a whole frame is now buffered. Gray-coded for the CDC to the
    // media domain, where it gates the start of transmission.
    // Counter width = FIFO addr width + 1. A narrower counter (was 4 bits)
    // aliases to a false "equal" once 2**width whole frames back up in the FIFO
    // (16 for 4 bits) - small frames reach that long before the 16K-byte FIFO
    // fills - deasserting tx_frame_pending_media and wedging the paced media
    // side. At ADDR_WIDTH+1 bits the byte FIFO fills first, so it cannot alias.
    localparam FRAME_CNT_W = 15;   // 14 (ADDR_WIDTH) + 1
    reg [FRAME_CNT_W-1:0] tx_frame_wr_count_bin;
    reg [FRAME_CNT_W-1:0] tx_frame_wr_count_gray;
    wire [FRAME_CNT_W-1:0] tx_frame_wr_count_next = tx_frame_wr_count_bin + 1'b1;
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tx_frame_wr_count_bin  <= {FRAME_CNT_W{1'b0}};
            tx_frame_wr_count_gray <= {FRAME_CNT_W{1'b0}};
        end else if (tx_eof_wr) begin
            tx_frame_wr_count_bin  <= tx_frame_wr_count_next;
            tx_frame_wr_count_gray <= tx_frame_wr_count_next ^
                                      (tx_frame_wr_count_next >> 1);
        end
    end

    // Saturate external level to 12 bits — most consumers only care about
    // coarse fill state.
    assign tx_fifo_level = (tx_fifo_count > 15'd4095) ? 12'hFFF
                                                     : tx_fifo_count[11:0];
    assign tx_busy       = (tx_fifo_count > TX_START_LIMIT);

    // TX data + EOF packet FIFO: sys_clk -> media_clk (16K words for jumbo)
    async_fifo #(.DATA_WIDTH(10), .ADDR_WIDTH(14),
                 .RAM_STYLE(FIFO_RAM_STYLE)) u_tx_fifo (
        .wr_clk  (sys_clk),
        .wr_rst_n(sys_rst_n),
        .wr_data (tx_wr_data),
        .wr_en   (tx_wr_accept),
        .wr_full (tx_wr_full),
        .rd_clk  (media_clk),
        .rd_rst_n(media_rst_n_s2),
        .rd_data (txd_rd_data),
        .rd_en   (txd_rd_en),
        .rd_empty(txd_rd_empty),
        .wr_data_count(tx_fifo_count)
    );

    // =========================================================================
    // TX control path: sys_clk GMII -> control packet FIFO -> media_clk, the
    // same word format and committed-frame counter as the data path. 128
    // words hold one 72-byte control frame plus the tail of the one before.
    // =========================================================================
    reg        ctl_en_d1;
    reg  [7:0] ctl_data_d1;
    reg        ctl_er_d1;
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            ctl_en_d1   <= 1'b0;
            ctl_data_d1 <= 8'd0;
            ctl_er_d1   <= 1'b0;
        end else begin
            ctl_en_d1   <= gmii_ctl_tx_en_in;
            ctl_data_d1 <= gmii_ctl_txd_in;
            ctl_er_d1   <= gmii_ctl_tx_er_in;
        end
    end
    wire ctl_en_fall = ctl_en_d1 && !gmii_ctl_tx_en_in;

    wire [9:0] ctl_wr_data   = {ctl_er_d1, ctl_en_fall, ctl_data_d1};
    wire       ctl_wr_full;
    wire       ctl_wr_accept = ctl_en_d1 && !ctl_wr_full;
    wire       ctl_eof_wr    = ctl_wr_accept && ctl_wr_data[8];
    wire [9:0] ctl_rd_data;
    wire       ctl_rd_empty;
    wire       ctl_rd_en;
    wire [7:0] ctl_fifo_count;

    // A 72-byte frame started with at most 55 words queued (and one more in
    // ctl_*_d1) fits the 128 words.
    assign tx_ctl_busy = (ctl_fifo_count > 8'd55);

    localparam CTL_CNT_W = 8;   // 7 (ADDR_WIDTH) + 1
    reg [CTL_CNT_W-1:0] ctl_frame_wr_count_bin;
    reg [CTL_CNT_W-1:0] ctl_frame_wr_count_gray;
    wire [CTL_CNT_W-1:0] ctl_frame_wr_count_next = ctl_frame_wr_count_bin + 1'b1;
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            ctl_frame_wr_count_bin  <= {CTL_CNT_W{1'b0}};
            ctl_frame_wr_count_gray <= {CTL_CNT_W{1'b0}};
        end else if (ctl_eof_wr) begin
            ctl_frame_wr_count_bin  <= ctl_frame_wr_count_next;
            ctl_frame_wr_count_gray <= ctl_frame_wr_count_next ^
                                       (ctl_frame_wr_count_next >> 1);
        end
    end

    async_fifo #(.DATA_WIDTH(10), .ADDR_WIDTH(7),
                 .RAM_STYLE("DISTRIBUTED")) u_ctl_fifo (
        .wr_clk  (sys_clk),
        .wr_rst_n(sys_rst_n),
        .wr_data (ctl_wr_data),
        .wr_en   (ctl_wr_accept),
        .wr_full (ctl_wr_full),
        .rd_clk  (media_clk),
        .rd_rst_n(media_rst_n_s2),
        .rd_data (ctl_rd_data),
        .rd_en   (ctl_rd_en),
        .rd_empty(ctl_rd_empty),
        .wr_data_count(ctl_fifo_count)
    );

    function [CTL_CNT_W-1:0] ctl_gray_to_bin;
        input [CTL_CNT_W-1:0] gray;
        integer i;
        begin
            ctl_gray_to_bin[CTL_CNT_W-1] = gray[CTL_CNT_W-1];
            for (i = CTL_CNT_W-2; i >= 0; i = i - 1)
                ctl_gray_to_bin[i] = ctl_gray_to_bin[i+1] ^ gray[i];
        end
    endfunction

    function [FRAME_CNT_W-1:0] gray_to_bin;
        input [FRAME_CNT_W-1:0] gray;
        integer i;
        begin
            gray_to_bin[FRAME_CNT_W-1] = gray[FRAME_CNT_W-1];
            for (i = FRAME_CNT_W-2; i >= 0; i = i - 1)
                gray_to_bin[i] = gray_to_bin[i+1] ^ gray[i];
        end
    endfunction

    // =========================================================================
    // Speed selection synchronizer (sys_clk -> media_clk)
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [1:0] cfg_speed_s1, cfg_speed_s2;
    always @(posedge media_clk or negedge media_rst_n_s2) begin
        if (!media_rst_n_s2) begin
            cfg_speed_s1 <= 2'b00;
            cfg_speed_s2 <= 2'b00;
        end else begin
            cfg_speed_s1 <= cfg_speed;
            cfg_speed_s2 <= cfg_speed_s1;
        end
    end
    wire is_1g  = (cfg_speed_s2 == 2'b00) || (cfg_speed_s2 == 2'b11);
    wire is_100 = (cfg_speed_s2 == 2'b01);
    wire is_10  = (cfg_speed_s2 == 2'b10);

    // Pacing: at 125 MHz media_clk, emit 1 byte per
    //   1G   = 8 ns  =  1 cycle  (pace_max = 0)
    //   100M = 80 ns = 10 cycles (pace_max = 9)
    //   10M  = 800ns = 100 cycles(pace_max = 99)
    wire [9:0] pace_max = is_1g ? 10'd0 : (is_100 ? 10'd9 : 10'd99);

    // Start delay before each frame, in media cycles. The TX FIFO is
    // store-and-forward, so the next frame can be waiting as soon as one ends
    // and the MAC framer's own IFG never reaches the wire: the gap is enforced
    // here at every speed. TX_EN is low for tx_gap + 2 cycles (one to close
    // out the frame, one to load the next), so 1G uses 10 for exactly 12 byte
    // times (the 96-bit-time IFG); 100M/10M get 122/1202 cycles, just over 12
    // byte times. Anything much shorter is invisible to the PHY at 2.5/25 MHz
    // and merges back-to-back frames on the wire.
    wire [10:0] tx_gap = is_1g ? 11'd10 : (is_100 ? 11'd120 : 11'd1200);

    // Committed-frame counter CDC into the media domain. tx_frame_pending_media
    // asserts once at least one whole frame has been committed to the FIFO but
    // not yet drained - the store-and-forward start gate.
    (* ASYNC_REG = "TRUE" *) reg [FRAME_CNT_W-1:0] tx_frame_wr_count_s1;
    (* ASYNC_REG = "TRUE" *) reg [FRAME_CNT_W-1:0] tx_frame_wr_count_s2;
    (* ASYNC_REG = "TRUE" *) reg [FRAME_CNT_W-1:0] tx_frame_wr_count_s3;
    reg [FRAME_CNT_W-1:0] tx_frame_rd_count_bin;
    always @(posedge media_clk or negedge media_rst_n_s2) begin
        if (!media_rst_n_s2) begin
            tx_frame_wr_count_s1 <= {FRAME_CNT_W{1'b0}};
            tx_frame_wr_count_s2 <= {FRAME_CNT_W{1'b0}};
            tx_frame_wr_count_s3 <= {FRAME_CNT_W{1'b0}};
        end else begin
            tx_frame_wr_count_s1 <= tx_frame_wr_count_gray;
            tx_frame_wr_count_s2 <= tx_frame_wr_count_s1;
            tx_frame_wr_count_s3 <= tx_frame_wr_count_s2;
        end
    end
    wire [FRAME_CNT_W-1:0] tx_frame_wr_count_media = gray_to_bin(tx_frame_wr_count_s3);
    wire       tx_frame_pending_media  =
                   (tx_frame_wr_count_media != tx_frame_rd_count_bin);

    // The same for the control FIFO.
    (* ASYNC_REG = "TRUE" *) reg [CTL_CNT_W-1:0] ctl_frame_wr_count_s1;
    (* ASYNC_REG = "TRUE" *) reg [CTL_CNT_W-1:0] ctl_frame_wr_count_s2;
    (* ASYNC_REG = "TRUE" *) reg [CTL_CNT_W-1:0] ctl_frame_wr_count_s3;
    reg [CTL_CNT_W-1:0] ctl_frame_rd_count_bin;
    always @(posedge media_clk or negedge media_rst_n_s2) begin
        if (!media_rst_n_s2) begin
            ctl_frame_wr_count_s1 <= {CTL_CNT_W{1'b0}};
            ctl_frame_wr_count_s2 <= {CTL_CNT_W{1'b0}};
            ctl_frame_wr_count_s3 <= {CTL_CNT_W{1'b0}};
        end else begin
            ctl_frame_wr_count_s1 <= ctl_frame_wr_count_gray;
            ctl_frame_wr_count_s2 <= ctl_frame_wr_count_s1;
            ctl_frame_wr_count_s3 <= ctl_frame_wr_count_s2;
        end
    end
    wire [CTL_CNT_W-1:0] ctl_frame_wr_count_media = ctl_gray_to_bin(ctl_frame_wr_count_s3);
    wire       ctl_frame_pending_media =
                   (ctl_frame_wr_count_media != ctl_frame_rd_count_bin);

    // tx_hold into the media domain.
    (* ASYNC_REG = "TRUE" *) reg tx_hold_s1, tx_hold_s2;
    always @(posedge media_clk or negedge media_rst_n_s2) begin
        if (!media_rst_n_s2) begin
            tx_hold_s1 <= 1'b0;
            tx_hold_s2 <= 1'b0;
        end else begin
            tx_hold_s1 <= tx_hold;
            tx_hold_s2 <= tx_hold_s1;
        end
    end

    // The selected FIFO: tx_sel_ctl is set when a frame is loaded and held
    // until the next one is, so the close-out pop (applied the cycle after the
    // frame ends) still reaches the FIFO the frame came from.
    reg        tx_sel_ctl;
    wire [9:0] tx_rd_data  = tx_sel_ctl ? ctl_rd_data  : txd_rd_data;
    wire       tx_rd_empty = tx_sel_ctl ? ctl_rd_empty : txd_rd_empty;
    assign     txd_rd_en   = tx_rd_en && !tx_sel_ctl;
    assign     ctl_rd_en   = tx_rd_en &&  tx_sel_ctl;

    // =========================================================================
    // TX readout state machine (media_clk domain)
    // =========================================================================
    // Read scheme (pacing unchanged from the length-FIFO revision):
    //   - A 1-cycle prefetch (start_delay==1) pulses rd_en so byte 0 is at the
    //     FWFT FIFO output for the first pace_tick while rd_en advances to byte 1,
    //     keeping the read pointer exactly one byte ahead of each paced emit.
    //     This avoids the NBA race that caused byte duplication / skips.
    //   - The frame ends when the emitted byte carries the EOF sideband bit,
    //     rather than when a preloaded byte counter reaches zero.
    reg       tx_frame_loaded;
    reg       tx_frame_end;
    reg [10:0] tx_start_delay;
    reg [9:0] pace_cnt;
    wire      pace_tick    = (pace_cnt == 10'd0);
    wire      pace_advance = (pace_max == 10'd0) || (pace_cnt == 10'd1);

    always @(posedge media_clk) begin
        if (!media_rst_n_s2) begin
            gmii_txd_out          <= 8'd0;
            gmii_tx_en_out        <= 1'b0;
            gmii_tx_er_out        <= 1'b0;
            tx_rd_en              <= 1'b0;
            tx_frame_loaded       <= 1'b0;
            tx_frame_end          <= 1'b0;
            tx_start_delay        <= 11'd0;
            tx_frame_rd_count_bin <= {FRAME_CNT_W{1'b0}};
            ctl_frame_rd_count_bin <= {CTL_CNT_W{1'b0}};
            tx_sel_ctl            <= 1'b0;
            pace_cnt              <= 10'd0;
        end else begin
            tx_rd_en <= 1'b0;

            if (pace_cnt == 10'd0)
                pace_cnt <= pace_max;
            else
                pace_cnt <= pace_cnt - 10'd1;

            if (!tx_frame_loaded) begin
                gmii_tx_en_out <= 1'b0;
                // Pick the next frame: a control frame first, else a data
                // frame unless held.
                if (ctl_frame_pending_media ||
                    (tx_frame_pending_media && !tx_hold_s2)) begin
                    tx_sel_ctl      <= ctl_frame_pending_media;
                    tx_start_delay  <= tx_gap;
                    tx_frame_loaded <= 1'b1;
                    pace_cnt        <= pace_max;
                end
            end else begin
                if (tx_start_delay > 11'd1 && !tx_sel_ctl &&
                    (tx_hold_s2 || ctl_frame_pending_media)) begin
                    // A data frame still in its start gap, before the prefetch
                    // below has touched the FIFO, gives way to a control frame
                    // or a hold. The next cycle picks again and the gap
                    // restarts, so it only grows.
                    tx_frame_loaded <= 1'b0;
                end else if (tx_start_delay != 11'd0) begin
                    tx_start_delay <= tx_start_delay - 11'd1;
                    gmii_tx_en_out <= 1'b0;
                    // Prefetch: pulse rd_en one cycle before start_delay==0 so
                    // byte 0 is at the FIFO output for the first pace_tick. Also
                    // align pace_cnt so pace_tick fires at start_delay==0.
                    if (tx_start_delay == 11'd1 && !tx_rd_empty) begin
                        tx_rd_en <= 1'b1;
                        pace_cnt <= 10'd0;
                    end
                end else if (tx_frame_end) begin
                    // The EOF byte was emitted at the last pace_tick. Hold it (and
                    // gmii_tx_en_out) for its full pace interval - close out only
                    // at the NEXT pace_tick, so the final byte occupies `period`
                    // media cycles like every other byte instead of just one (a
                    // 1-cycle last byte can be mis-sampled by a paced downstream).
                    // At 1G pace_tick is always asserted, so this closes out the
                    // next cycle exactly as before.
                    if (pace_tick) begin
                        // Advance past the EOF word: its per-byte advance is
                        // suppressed above (don't prefetch past EOF), so without
                        // this the read pointer would be left on the EOF byte and
                        // the next paced frame would emit that stale byte, see EOF,
                        // and end immediately - a phantom frame that orphans the
                        // real frame. Paced modes only: at 1G the every-cycle
                        // prefetch already realigns the pointer.
                        if (!is_1g)
                            tx_rd_en          <= 1'b1;
                        gmii_tx_en_out        <= 1'b0;
                        tx_frame_loaded       <= 1'b0;
                        tx_frame_end          <= 1'b0;
                        if (tx_sel_ctl)
                            ctl_frame_rd_count_bin <= ctl_frame_rd_count_bin + 1'b1;
                        else
                            tx_frame_rd_count_bin  <= tx_frame_rd_count_bin + 1'b1;
                    end
                end else if (!tx_rd_empty) begin
                    if (pace_tick) begin
                        gmii_txd_out   <= tx_rd_data[7:0];
                        gmii_tx_en_out <= 1'b1;
                        gmii_tx_er_out <= tx_rd_data[9];  // per-byte error passthrough
                        if (tx_rd_data[8])
                            tx_frame_end <= 1'b1;   // last byte of the frame
                    end
                    // Pulse rd_en the cycle before the NEXT pace_tick so the FIFO
                    // advance is visible exactly at that capture edge. Don't
                    // prefetch past the last (EOF) byte.
                    if (pace_advance && !tx_rd_data[8])
                        tx_rd_en <= 1'b1;
                    // Hold gmii_tx_en_out high between paced beats so the RGMII
                    // PHY sees a continuous frame.
                end
            end
        end
    end

endmodule
