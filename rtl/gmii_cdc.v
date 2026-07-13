// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// gmii_cdc.v - GMII Clock Domain Crossing Bridge (for RGMII/Gigabit)
// Store-and-forward CDC between system clock and media clock domains.
// No nibble conversion — both sides are 8-bit GMII.
// Verilog 2001
// =============================================================================

module gmii_cdc (
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
    input  wire        gmii_rx_dv_in,
    input  wire        gmii_rx_er_in,

    // ---- Status ----
    output wire        tx_busy,
    output wire [11:0] tx_fifo_level
);

    // =========================================================================
    // Reset synchronizers
    // =========================================================================
    reg media_rst_n_s1, media_rst_n_s2;
    reg media_rx_rst_n_s1, media_rx_rst_n_s2;
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
    // FIFO data: [9] = EOF marker, [8] = error, [7:0] = data
    reg [9:0]  rx_wr_data;
    reg        rx_wr_en;
    wire       rx_wr_full;
    reg        rx_dv_d1;

    always @(posedge media_rx_clk or negedge media_rx_rst_n_s2) begin
        if (!media_rx_rst_n_s2) begin
            rx_wr_data <= 10'd0;
            rx_wr_en   <= 1'b0;
            rx_dv_d1   <= 1'b0;
        end else begin
            rx_wr_en <= 1'b0;
            rx_dv_d1 <= gmii_rx_dv_in;

            if (gmii_rx_dv_in) begin
                rx_wr_data <= {1'b0, gmii_rx_er_in, gmii_rxd_in};
                rx_wr_en   <= 1'b1;
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
        else if (rx_wr_en && rx_wr_data[9])
            rx_frame_toggle <= ~rx_frame_toggle;
    end

    // RX async FIFO
    wire [9:0] rx_rd_data;
    wire       rx_rd_empty;
    reg        rx_rd_en;

    async_fifo #(.DATA_WIDTH(10), .ADDR_WIDTH(12)) u_rx_fifo (
        .wr_clk  (media_rx_clk),
        .wr_rst_n(media_rx_rst_n_s2),
        .wr_data (rx_wr_data),
        .wr_en   (rx_wr_en && !rx_wr_full),
        .wr_full (rx_wr_full),
        .rd_clk  (sys_clk),
        .rd_rst_n(sys_rst_n),
        .rd_data (rx_rd_data),
        .rd_en   (rx_rd_en),
        .rd_empty(rx_rd_empty),
        .wr_data_count()
    );

    // Frame availability tracking (sys_clk domain)
    (* ASYNC_REG = "TRUE" *) reg rx_toggle_s1, rx_toggle_s2, rx_toggle_s3;
    reg [7:0]  rx_avail_delay;
    reg [3:0]  rx_frames_pending;
    reg        rx_frame_done_pulse;
    reg        rx_reading;

    wire rx_frame_avail   = (rx_toggle_s2 != rx_toggle_s3);
    wire rx_frame_avail_d = rx_avail_delay[7];
    wire rx_frame_ready   = (rx_frames_pending > 0);

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rx_toggle_s1    <= 1'b0;
            rx_toggle_s2    <= 1'b0;
            rx_toggle_s3    <= 1'b0;
            rx_avail_delay  <= 8'd0;
            rx_frames_pending <= 4'd0;
        end else begin
            rx_toggle_s1 <= rx_frame_toggle;
            rx_toggle_s2 <= rx_toggle_s1;
            rx_toggle_s3 <= rx_toggle_s2;
            rx_avail_delay <= {rx_avail_delay[6:0], rx_frame_avail};

            case ({rx_frame_avail_d, rx_frame_done_pulse})
                2'b10: rx_frames_pending <= rx_frames_pending + 4'd1;
                2'b01: if (rx_frames_pending != 4'd0)
                           rx_frames_pending <= rx_frames_pending - 4'd1;
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
        end else begin
            rx_rd_en            <= 1'b0;
            gmii_rx_dv_out      <= 1'b0;
            gmii_rx_er_out      <= 1'b0;
            rx_frame_done_pulse <= 1'b0;

            if (rx_reading) begin
                if (!rx_rd_empty) begin
                    if (rx_rd_data[9]) begin
                        rx_rd_en            <= 1'b1;
                        rx_reading          <= 1'b0;
                        rx_frame_done_pulse <= 1'b1;
                    end else begin
                        gmii_rxd_out   <= rx_rd_data[7:0];
                        gmii_rx_dv_out <= 1'b1;
                        gmii_rx_er_out <= rx_rd_data[8];
                        rx_rd_en       <= 1'b1;
                    end
                end else if (!rx_frame_ready) begin
                    rx_reading <= 1'b0;
                end
            end else if (rx_frame_ready && !rx_rd_empty) begin
                rx_reading <= 1'b1;
                rx_rd_en   <= 1'b1;  // align first readable word from behavioral FIFO
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
    reg        tx_valid_d1;
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tx_en_d1    <= 1'b0;
            tx_data_d1  <= 8'd0;
            tx_valid_d1 <= 1'b0;
        end else begin
            tx_en_d1    <= gmii_tx_en_in;
            tx_data_d1  <= gmii_txd_in;
            tx_valid_d1 <= gmii_tx_en_in;
        end
    end
    wire tx_en_fall = tx_en_d1 && !gmii_tx_en_in;

    // FIFO word: [8] = EOF (set on the frame's last byte), [7:0] = data.
    wire [8:0] tx_wr_data   = {tx_en_fall, tx_data_d1};
    wire       tx_wr_en     = tx_valid_d1;
    wire       tx_wr_full;
    wire       tx_wr_accept = tx_wr_en && !tx_wr_full;
    wire       tx_eof_wr    = tx_wr_accept && tx_wr_data[8];

    wire [8:0] tx_rd_data;
    wire       tx_rd_empty;
    reg        tx_rd_en;

    // FIFO occupancy (sys_clk / write domain), taken directly from the async
    // FIFO's exact write-side data count (wr_ptr - synced rd_ptr).
    wire [14:0] tx_fifo_count;

    localparam [14:0] TX_FIFO_DEPTH      = 15'd16383;
    localparam [14:0] TX_MAX_FRAME_BYTES = 15'd9018;   // jumbo MTU + headers
    localparam [14:0] TX_START_LIMIT     = TX_FIFO_DEPTH - TX_MAX_FRAME_BYTES;

    // Committed-frame counter (sys_clk): increments when a frame's EOF byte is
    // accepted, i.e. a whole frame is now buffered. Gray-coded for the CDC to the
    // media domain, where it gates the start of transmission.
    reg [3:0] tx_frame_wr_count_bin;
    reg [3:0] tx_frame_wr_count_gray;
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tx_frame_wr_count_bin  <= 4'd0;
            tx_frame_wr_count_gray <= 4'd0;
        end else if (tx_eof_wr) begin
            tx_frame_wr_count_bin  <= tx_frame_wr_count_bin + 4'd1;
            tx_frame_wr_count_gray <= (tx_frame_wr_count_bin + 4'd1) ^
                                       ((tx_frame_wr_count_bin + 4'd1) >> 1);
        end
    end

    // Saturate external level to 12 bits — most consumers only care about
    // coarse fill state.
    assign tx_fifo_level = (tx_fifo_count > 15'd4095) ? 12'hFFF
                                                     : tx_fifo_count[11:0];
    assign tx_busy       = (tx_fifo_count > TX_START_LIMIT);

    // TX data + EOF packet FIFO: sys_clk -> media_clk (16K words for jumbo)
    async_fifo #(.DATA_WIDTH(9), .ADDR_WIDTH(14)) u_tx_fifo (
        .wr_clk  (sys_clk),
        .wr_rst_n(sys_rst_n),
        .wr_data (tx_wr_data),
        .wr_en   (tx_wr_accept),
        .wr_full (tx_wr_full),
        .rd_clk  (media_clk),
        .rd_rst_n(media_rst_n_s2),
        .rd_data (tx_rd_data),
        .rd_en   (tx_rd_en),
        .rd_empty(tx_rd_empty),
        .wr_data_count(tx_fifo_count)
    );

    function [3:0] gray4_to_bin;
        input [3:0] gray;
        begin
            gray4_to_bin[3] = gray[3];
            gray4_to_bin[2] = gray4_to_bin[3] ^ gray[2];
            gray4_to_bin[1] = gray4_to_bin[2] ^ gray[1];
            gray4_to_bin[0] = gray4_to_bin[1] ^ gray[0];
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

    // Committed-frame counter CDC into the media domain. tx_frame_pending_media
    // asserts once at least one whole frame has been committed to the FIFO but
    // not yet drained - the store-and-forward start gate.
    (* ASYNC_REG = "TRUE" *) reg [3:0] tx_frame_wr_count_s1;
    (* ASYNC_REG = "TRUE" *) reg [3:0] tx_frame_wr_count_s2;
    (* ASYNC_REG = "TRUE" *) reg [3:0] tx_frame_wr_count_s3;
    reg [3:0] tx_frame_rd_count_bin;
    always @(posedge media_clk or negedge media_rst_n_s2) begin
        if (!media_rst_n_s2) begin
            tx_frame_wr_count_s1 <= 4'd0;
            tx_frame_wr_count_s2 <= 4'd0;
            tx_frame_wr_count_s3 <= 4'd0;
        end else begin
            tx_frame_wr_count_s1 <= tx_frame_wr_count_gray;
            tx_frame_wr_count_s2 <= tx_frame_wr_count_s1;
            tx_frame_wr_count_s3 <= tx_frame_wr_count_s2;
        end
    end
    wire [3:0] tx_frame_wr_count_media = gray4_to_bin(tx_frame_wr_count_s3);
    wire       tx_frame_pending_media  =
                   (tx_frame_wr_count_media != tx_frame_rd_count_bin);

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
    reg [5:0] tx_start_delay;
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
            tx_start_delay        <= 6'd0;
            tx_frame_rd_count_bin <= 4'd0;
            pace_cnt              <= 10'd0;
        end else begin
            tx_rd_en <= 1'b0;

            if (pace_cnt == 10'd0)
                pace_cnt <= pace_max;
            else
                pace_cnt <= pace_cnt - 10'd1;

            if (!tx_frame_loaded && tx_frame_pending_media) begin
                tx_start_delay  <= 6'd8;
                tx_frame_loaded <= 1'b1;
                pace_cnt        <= pace_max;
            end else if (tx_frame_loaded) begin
                if (tx_start_delay != 6'd0) begin
                    tx_start_delay <= tx_start_delay - 6'd1;
                    gmii_tx_en_out <= 1'b0;
                    // Prefetch: pulse rd_en one cycle before start_delay==0 so
                    // byte 0 is at the FIFO output for the first pace_tick. Also
                    // align pace_cnt so pace_tick fires at start_delay==0.
                    if (tx_start_delay == 6'd1 && !tx_rd_empty) begin
                        tx_rd_en <= 1'b1;
                        pace_cnt <= 10'd0;
                    end
                end else if (tx_frame_end) begin
                    // Emitted the EOF byte last cycle; close out the frame.
                    gmii_tx_en_out        <= 1'b0;
                    tx_frame_loaded       <= 1'b0;
                    tx_frame_end          <= 1'b0;
                    tx_frame_rd_count_bin <= tx_frame_rd_count_bin + 4'd1;
                end else if (!tx_rd_empty) begin
                    if (pace_tick) begin
                        gmii_txd_out   <= tx_rd_data[7:0];
                        gmii_tx_en_out <= 1'b1;
                        gmii_tx_er_out <= 1'b0;
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
            end else begin
                gmii_tx_en_out <= 1'b0;
            end
        end
    end

endmodule
