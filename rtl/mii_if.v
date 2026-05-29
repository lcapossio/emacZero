// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// mii_if.v - MII PHY Interface with Store-and-Forward CDC
// Converts between 8-bit GMII (100 MHz sys_clk) and 4-bit MII (25 MHz PHY)
// Verilog 2001
// =============================================================================

module mii_if #(
    parameter MII_DEBUG = 0
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [3:0]  mii_rxd,
    input  wire        mii_rx_dv,
    input  wire        mii_rx_er,
    input  wire        mii_rx_clk,
    input  wire        mii_col,
    input  wire        mii_crs,

    output wire [3:0]  mii_txd,
    output wire        mii_tx_en,
    input  wire        mii_tx_clk,

    input  wire [7:0]  gmii_txd,
    input  wire        gmii_tx_en,
    input  wire        gmii_tx_er,
    output reg  [7:0]  gmii_rxd,
    output reg         gmii_rx_dv,
    output reg         gmii_rx_er,
    output wire        mii_tx_clk_out,
    output wire        tx_busy,
    output wire [12:0] tx_fifo_level,
    output wire        dbg_tx_fifo_empty,
    output wire        dbg_rx_prog_empty,
    output wire        dbg_rx_rd_empty,
    output wire        dbg_rx_reading,
    output wire [1:0]  dbg_rx_frames_pending,
    // TX path internals for debug
    output wire        dbg_tx_wr_en,
    output wire        dbg_tx_len_wr_en,
    output wire        dbg_tx_wr_full,
    output wire        dbg_tx_wr_rst_busy_out,
    output wire        dbg_tx_rd_en,
    output wire        dbg_tx_frame_loaded,
    output wire [11:0] dbg_tx_frames_queued,
    output wire [11:0] dbg_tx_frames_drained,
    output wire [11:0] dbg_last_tx_len_wr,
    // MII TX byte capture (CDC'd to sys_clk) - first 64 bytes per frame, latest
    output wire        dbg_mii_cap_done,
    output wire [11:0] dbg_mii_cap_frame_len,
    output wire [31:0] dbg_mii_cap_word0,
    output wire [31:0] dbg_mii_cap_word1,
    output wire [31:0] dbg_mii_cap_word2,
    output wire [31:0] dbg_mii_cap_word3,
    output wire [31:0] dbg_mii_cap_word4,
    output wire [31:0] dbg_mii_cap_word5,
    output wire [31:0] dbg_mii_cap_word6,
    output wire [31:0] dbg_mii_cap_word7,
    output wire [31:0] dbg_mii_cap_word8,
    output wire [31:0] dbg_mii_cap_word9,
    output wire [31:0] dbg_mii_cap_word10,
    output wire [31:0] dbg_mii_cap_word11,
    output wire [31:0] dbg_mii_cap_word12,
    output wire [31:0] dbg_mii_cap_word13,
    output wire [31:0] dbg_mii_cap_word14,
    output wire [31:0] dbg_mii_cap_word15,
    output wire [3:0]  dbg_mii_txd_pre_iob,
    output wire        dbg_mii_tx_en_pre_iob,
    output wire [31:0] dbg_rx_fifo_full_frames,
    output wire [31:0] dbg_rx_fifo_full_writes,
    output wire [31:0] dbg_rx_fifo_overflow_pulses,
    output wire [31:0] dbg_rx_fifo_wr_level_max,
    output wire [31:0] dbg_rx_replay_gap_frames,
    output wire [31:0] dbg_rx_replay_gap_cycles,
    output wire [31:0] dbg_rx_replay_gap_byte_max,
    output wire [31:0] dbg_rx_mii_last_len,
    output wire [31:0] dbg_rx_mii_word0,
    output wire [31:0] dbg_rx_mii_word1,
    output wire [31:0] dbg_rx_mii_word2,
    output wire [31:0] dbg_rx_mii_word3,
    output wire [31:0] dbg_rx_mii_word4,
    output wire [31:0] dbg_rx_mii_word5,
    output wire [31:0] dbg_rx_mii_word6,
    output wire [31:0] dbg_rx_mii_word7,
    output wire [31:0] dbg_rx_mii_word8,
    output wire [31:0] dbg_rx_mii_word9,
    output wire [31:0] dbg_rx_mii_word10,
    output wire [31:0] dbg_rx_mii_word11,
    output wire [31:0] dbg_rx_mii_word12,
    output wire [31:0] dbg_rx_mii_word13,
    output wire [31:0] dbg_rx_mii_word14,
    output wire [31:0] dbg_rx_mii_word15,
    output wire [31:0] dbg_rx_replay_last_len,
    output wire [31:0] dbg_rx_replay_word0,
    output wire [31:0] dbg_rx_replay_word1,
    output wire [31:0] dbg_rx_replay_word2,
    output wire [31:0] dbg_rx_replay_word3,
    output wire [31:0] dbg_rx_replay_eof_count,
    // gmii_tx_er visibility (sys_clk domain). pulse count = rising-edge
    // assertions of gmii_tx_er; frame count = frames during which gmii_tx_er
    // was asserted at least once.
    output wire [31:0] dbg_tx_er_pulses,
    output wire [31:0] dbg_tx_er_frames
);

    assign mii_tx_clk_out = mii_tx_clk;

    reg rx_rst_n_s1, rx_rst_n_s2;
    reg tx_rst_n_s1, tx_rst_n_s2;

    always @(posedge mii_rx_clk or negedge rst_n) begin
        if (!rst_n) {rx_rst_n_s2, rx_rst_n_s1} <= 2'b00;
        else        {rx_rst_n_s2, rx_rst_n_s1} <= {rx_rst_n_s1, 1'b1};
    end

    always @(posedge mii_tx_clk or negedge rst_n) begin
        if (!rst_n) {tx_rst_n_s2, tx_rst_n_s1} <= 2'b00;
        else        {tx_rst_n_s2, tx_rst_n_s1} <= {tx_rst_n_s1, 1'b1};
    end

    // =========================================================================
    // RX path: MII -> store-and-forward FIFO -> GMII
    // =========================================================================
    reg        rx_nib_sel;
    reg [3:0]  rx_nib_low;
    reg        rx_er_low;
    reg        rx_dv_d1;

    // Dedicated RX input capture stage so Vivado has a clean IOB-friendly
    // first register bank on the PHY-facing MII inputs.
    (* IOB = "TRUE" *) reg [3:0] mii_rxd_iob;
    (* IOB = "TRUE" *) reg       mii_rx_dv_iob;
    (* IOB = "TRUE" *) reg       mii_rx_er_iob;

    reg [9:0]  rx_wr_data;
    reg        rx_wr_en;
    wire       rx_wr_full;
    wire       rx_wr_accept;
    wire       rx_full_write;
    wire       rx_fifo_overflow;
    wire [12:0] rx_wr_data_count;
    reg        rx_fifo_full_seen;
    reg        rx_fifo_full_frame_toggle;
    reg        rx_fifo_full_write_toggle;
    reg        rx_fifo_overflow_toggle;
    reg [12:0] rx_fifo_wr_level_max_rxclk;
    reg        rx_mii_frame_toggle;
    reg [15:0] rx_mii_byte_count_rxclk;
    reg [15:0] rx_mii_last_len_rxclk;
    // 64-byte raw MII-RX byte capture (first 64 bytes of each frame, overwriting).
    // Packed into 16 32-bit words for CDC + CSR exposure.
    reg [7:0]  rx_mii_cap_rxclk [0:63];
    integer    rxi;
    wire [31:0] rx_mii_word_rxclk [0:15];
    genvar rwi;
    generate
        for (rwi = 0; rwi < 16; rwi = rwi + 1) begin : g_rx_pack
            assign rx_mii_word_rxclk[rwi] =
                {rx_mii_cap_rxclk[rwi*4+0], rx_mii_cap_rxclk[rwi*4+1],
                 rx_mii_cap_rxclk[rwi*4+2], rx_mii_cap_rxclk[rwi*4+3]};
        end
    endgenerate

    assign rx_full_write = rx_wr_en && rx_wr_full;
    assign rx_wr_accept = rx_wr_en && !rx_wr_full && !rx_wr_rst_busy;

    always @(posedge mii_rx_clk or negedge rx_rst_n_s2) begin
        if (!rx_rst_n_s2) begin
            mii_rxd_iob   <= 4'd0;
            mii_rx_dv_iob <= 1'b0;
            mii_rx_er_iob <= 1'b0;
        end else begin
            mii_rxd_iob   <= mii_rxd;
            mii_rx_dv_iob <= mii_rx_dv;
            mii_rx_er_iob <= mii_rx_er;
        end
    end

    always @(posedge mii_rx_clk or negedge rx_rst_n_s2) begin
        if (!rx_rst_n_s2) begin
            rx_nib_sel <= 1'b0;
            rx_nib_low <= 4'd0;
            rx_er_low  <= 1'b0;
            rx_dv_d1   <= 1'b0;
            rx_wr_data <= 10'd0;
            rx_wr_en   <= 1'b0;
            rx_fifo_full_seen <= 1'b0;
            if (MII_DEBUG != 0) begin
                rx_fifo_full_frame_toggle <= 1'b0;
                rx_fifo_full_write_toggle <= 1'b0;
                rx_fifo_overflow_toggle <= 1'b0;
                rx_fifo_wr_level_max_rxclk <= 13'd0;
                rx_mii_frame_toggle <= 1'b0;
                rx_mii_byte_count_rxclk <= 16'd0;
                rx_mii_last_len_rxclk <= 16'd0;
                for (rxi = 0; rxi < 64; rxi = rxi + 1)
                    rx_mii_cap_rxclk[rxi] <= 8'd0;
            end
        end else begin
            rx_wr_en <= 1'b0;
            rx_dv_d1 <= mii_rx_dv_iob;
            if ((MII_DEBUG != 0) && (rx_wr_data_count > rx_fifo_wr_level_max_rxclk))
                rx_fifo_wr_level_max_rxclk <= rx_wr_data_count;

            if (rx_full_write) begin
                rx_fifo_full_seen <= 1'b1;
                if (MII_DEBUG != 0)
                    rx_fifo_full_write_toggle <= ~rx_fifo_full_write_toggle;
            end
            if ((MII_DEBUG != 0) && rx_fifo_overflow)
                rx_fifo_overflow_toggle <= ~rx_fifo_overflow_toggle;

            if (mii_rx_dv_iob) begin
                if (!rx_nib_sel) begin
                    rx_nib_low <= mii_rxd_iob;
                    rx_er_low  <= mii_rx_er_iob;
                    rx_nib_sel <= 1'b1;
                end else begin
                    rx_wr_data <= {1'b0, rx_er_low | mii_rx_er_iob |
                                   rx_fifo_full_seen | rx_full_write,
                                   mii_rxd_iob, rx_nib_low};
                    rx_wr_en   <= 1'b1;
                    rx_nib_sel <= 1'b0;
                    if (MII_DEBUG != 0) begin
                        // First-64-byte capture (no wrap). byte_count is the
                        // index of the byte we are committing this cycle.
                        if (rx_mii_byte_count_rxclk[15:6] == 10'd0)
                            rx_mii_cap_rxclk[rx_mii_byte_count_rxclk[5:0]]
                                <= {mii_rxd_iob, rx_nib_low};
                        rx_mii_byte_count_rxclk <= rx_mii_byte_count_rxclk + 1'b1;
                    end
                end
            end else begin
                rx_nib_sel <= 1'b0;
                if (rx_dv_d1) begin
                    rx_wr_data <= {1'b1, rx_fifo_full_seen, 8'h00};
                    rx_wr_en   <= 1'b1;
                    if (MII_DEBUG != 0) begin
                        rx_mii_last_len_rxclk <= rx_mii_byte_count_rxclk;
                        rx_mii_frame_toggle <= ~rx_mii_frame_toggle;
                        rx_mii_byte_count_rxclk <= 16'd0;
                        if (rx_fifo_full_seen)
                            rx_fifo_full_frame_toggle <= ~rx_fifo_full_frame_toggle;
                    end
                    rx_fifo_full_seen <= 1'b0;
                end
            end
        end
    end

    wire [9:0] rx_rd_data;
    wire       rx_rd_empty;
    wire       rx_rd_valid;
    reg        rx_rd_en;
    wire       rx_wr_rst_busy;
    wire       rx_rd_rst_busy;
    wire       rx_prog_empty;
    wire       rx_rd_word_valid;
    wire [12:0] rx_rd_data_count;

    reg [3:0]  rx_frame_wr_count_bin;
    reg [3:0]  rx_frame_wr_count_gray;
    (* ASYNC_REG = "TRUE" *) reg [3:0] rx_frame_wr_count_s1;
    (* ASYNC_REG = "TRUE" *) reg [3:0] rx_frame_wr_count_s2;
    (* ASYNC_REG = "TRUE" *) reg [3:0] rx_frame_wr_count_s3;
    reg [3:0]  rx_frame_rd_count_bin;

    always @(posedge mii_rx_clk or negedge rx_rst_n_s2) begin
        if (!rx_rst_n_s2) begin
            rx_frame_wr_count_bin  <= 4'd0;
            rx_frame_wr_count_gray <= 4'd0;
        end else begin
            if (rx_wr_accept && rx_wr_data[9]) begin
                rx_frame_wr_count_bin  <= rx_frame_wr_count_bin + 4'd1;
                rx_frame_wr_count_gray <= (rx_frame_wr_count_bin + 4'd1) ^
                                           ((rx_frame_wr_count_bin + 4'd1) >> 1);
            end
        end
    end

    function [3:0] gray4_to_bin;
        input [3:0] gray;
        begin
            gray4_to_bin[3] = gray[3];
            gray4_to_bin[2] = gray4_to_bin[3] ^ gray[2];
            gray4_to_bin[1] = gray4_to_bin[2] ^ gray[1];
            gray4_to_bin[0] = gray4_to_bin[1] ^ gray[0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_frame_wr_count_s1 <= 4'd0;
            rx_frame_wr_count_s2 <= 4'd0;
            rx_frame_wr_count_s3 <= 4'd0;
            rx_frame_rd_count_bin <= 4'd0;
        end else begin
            rx_frame_wr_count_s1 <= rx_frame_wr_count_gray;
            rx_frame_wr_count_s2 <= rx_frame_wr_count_s1;
            rx_frame_wr_count_s3 <= rx_frame_wr_count_s2;
            if (rx_frame_done_pulse) begin
                rx_frame_rd_count_bin <= rx_frame_rd_count_bin + 4'd1;
            end
        end
    end

    wire [3:0] rx_frame_wr_count_sys = gray4_to_bin(rx_frame_wr_count_s3);
    wire       rx_frame_pending_sys = (rx_frame_wr_count_sys != rx_frame_rd_count_bin);
    localparam [31:0] RX_FIFO_ADV_FEATURES = (MII_DEBUG != 0) ? "1F1F" : "1000";

`ifdef XILINX_7SERIES
    xpm_fifo_async #(
        .FIFO_WRITE_DEPTH(4096),
        .WRITE_DATA_WIDTH(10),
        .READ_DATA_WIDTH(10),
        .READ_MODE("FWFT"),
        .FIFO_READ_LATENCY(0),
        .CDC_SYNC_STAGES(3),
        .DOUT_RESET_VALUE("0"),
        .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(64),
        .PROG_FULL_THRESH(10),
        .RD_DATA_COUNT_WIDTH(13),
        .WR_DATA_COUNT_WIDTH(13),
        .USE_ADV_FEATURES(RX_FIFO_ADV_FEATURES),
        .WAKEUP_TIME(0)
    ) u_rx_fifo (
        .wr_clk        (mii_rx_clk),
        .wr_en         (rx_wr_accept),
        .din           (rx_wr_data),
        .full          (rx_wr_full),
        .wr_rst_busy   (rx_wr_rst_busy),
        .rd_clk        (clk),
        .rd_en         (rx_rd_en && !rx_rd_rst_busy),
        .dout          (rx_rd_data),
        .empty         (rx_rd_empty),
        .rd_rst_busy   (rx_rd_rst_busy),
        .rst           (~rx_rst_n_s2),
        .sleep         (1'b0),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0),
        .sbiterr       (),
        .dbiterr       (),
        .overflow      (rx_fifo_overflow),
        .underflow     (),
        .prog_full     (),
        .prog_empty    (rx_prog_empty),
        .almost_full   (),
        .almost_empty  (),
        .wr_data_count (rx_wr_data_count),
        .rd_data_count (rx_rd_data_count),
        .data_valid    (rx_rd_valid),
        .wr_ack        ()
    );

`else
    assign rx_prog_empty = 1'b1;
    assign rx_wr_rst_busy = 1'b0;
    assign rx_rd_rst_busy = 1'b0;
    assign rx_fifo_overflow = rx_full_write;
    assign rx_wr_data_count = 13'd0;
    assign rx_rd_data_count = rx_rd_empty ? 13'd0 : 13'h1fff;
    assign rx_rd_valid = !rx_rd_empty;
    async_fifo #(.DATA_WIDTH(10), .ADDR_WIDTH(11)) u_rx_fifo (
        .wr_clk  (mii_rx_clk),
        .wr_rst_n(rx_rst_n_s2),
        .wr_data (rx_wr_data),
        .wr_en   (rx_wr_accept),
        .wr_full (rx_wr_full),
        .rd_clk  (clk),
        .rd_rst_n(rst_n),
        .rd_data (rx_rd_data),
        .rd_en   (rx_rd_en),
        .rd_empty(rx_rd_empty)
    );

`endif

    // In FWFT mode, empty can remain deasserted while the previous word is
    // still present after rd_en. Use data_valid so replay only consumes a word
    // when the FIFO has presented fresh data; otherwise bytes can be duplicated
    // inside the reconstructed GMII frame and FCS will fail.
    assign rx_rd_word_valid = rx_rd_valid && !rx_rd_rst_busy;

    localparam [2:0]
        RX_REPLAY_IDLE  = 3'd0,
        RX_REPLAY_LOAD  = 3'd1,
        RX_REPLAY_PRIME = 3'd2,
        RX_REPLAY_WAIT  = 3'd3,
        RX_REPLAY_SEND  = 3'd4;

    reg [2:0]  rx_replay_state;
    reg        rx_load_wait;
    reg [15:0] rx_load_count;
    reg [15:0] rx_replay_len;
    reg [15:0] rx_replay_index;
    reg [15:0] rx_mem_rd_addr;
    reg [8:0]  rx_mem_rd_data;
    reg        rx_mem_wr_en;
    reg [11:0] rx_mem_wr_addr;
    reg [8:0]  rx_mem_wr_data;
    wire       rx_mem_rd_en;
    wire [11:0] rx_mem_rd_addr_reg;
    wire [8:0] rx_frame_mem_dout;
    (* ASYNC_REG = "TRUE" *) reg rx_full_frame_s1, rx_full_frame_s2, rx_full_frame_s3;
    (* ASYNC_REG = "TRUE" *) reg rx_full_write_s1, rx_full_write_s2, rx_full_write_s3;
    (* ASYNC_REG = "TRUE" *) reg rx_overflow_s1, rx_overflow_s2, rx_overflow_s3;
    (* ASYNC_REG = "TRUE" *) reg rx_mii_frame_s1, rx_mii_frame_s2, rx_mii_frame_s3;
    (* ASYNC_REG = "TRUE" *) reg [12:0] rx_wr_level_max_s1, rx_wr_level_max_s2;
    reg        rx_frame_done_pulse;
    reg [31:0] rx_fifo_full_frames_sys;
    reg [31:0] rx_fifo_full_writes_sys;
    reg [31:0] rx_fifo_overflow_pulses_sys;
    reg [31:0] rx_fifo_wr_level_max_sys;
    reg [31:0] rx_replay_gap_frames_sys;
    reg [31:0] rx_replay_gap_cycles_sys;
    reg [31:0] rx_replay_gap_byte_max_sys;
    reg [15:0] rx_replay_byte_count;
    reg        rx_replay_gap_seen;
    reg [31:0] rx_mii_last_len_sys;
    // 16 sysclk-domain capture words (64 bytes per frame, latched on frame-end)
    reg [31:0] rx_mii_word_sys [0:15];
    integer    rxsi;
    reg [31:0] rx_replay_last_len_sys;
    reg [31:0] rx_replay_word0_sys;
    reg [31:0] rx_replay_word1_sys;
    reg [31:0] rx_replay_word2_sys;
    reg [31:0] rx_replay_word3_sys;
    reg [31:0] rx_replay_eof_count_sys;

    wire rx_frame_ready = rx_frame_pending_sys && !rx_rd_rst_busy;

    assign dbg_rx_fifo_full_frames = (MII_DEBUG != 0) ? rx_fifo_full_frames_sys : 32'd0;
    assign dbg_rx_fifo_full_writes = (MII_DEBUG != 0) ? rx_fifo_full_writes_sys : 32'd0;
    assign dbg_rx_fifo_overflow_pulses = (MII_DEBUG != 0) ? rx_fifo_overflow_pulses_sys : 32'd0;
    assign dbg_rx_fifo_wr_level_max = (MII_DEBUG != 0) ? rx_fifo_wr_level_max_sys : 32'd0;
    assign dbg_rx_replay_gap_frames = (MII_DEBUG != 0) ? rx_replay_gap_frames_sys : 32'd0;
    assign dbg_rx_replay_gap_cycles = (MII_DEBUG != 0) ? rx_replay_gap_cycles_sys : 32'd0;
    assign dbg_rx_replay_gap_byte_max = (MII_DEBUG != 0) ? rx_replay_gap_byte_max_sys : 32'd0;
    assign dbg_rx_mii_last_len = (MII_DEBUG != 0) ? rx_mii_last_len_sys : 32'd0;
    assign dbg_rx_mii_word0  = (MII_DEBUG != 0) ? rx_mii_word_sys[ 0] : 32'd0;
    assign dbg_rx_mii_word1  = (MII_DEBUG != 0) ? rx_mii_word_sys[ 1] : 32'd0;
    assign dbg_rx_mii_word2  = (MII_DEBUG != 0) ? rx_mii_word_sys[ 2] : 32'd0;
    assign dbg_rx_mii_word3  = (MII_DEBUG != 0) ? rx_mii_word_sys[ 3] : 32'd0;
    assign dbg_rx_mii_word4  = (MII_DEBUG != 0) ? rx_mii_word_sys[ 4] : 32'd0;
    assign dbg_rx_mii_word5  = (MII_DEBUG != 0) ? rx_mii_word_sys[ 5] : 32'd0;
    assign dbg_rx_mii_word6  = (MII_DEBUG != 0) ? rx_mii_word_sys[ 6] : 32'd0;
    assign dbg_rx_mii_word7  = (MII_DEBUG != 0) ? rx_mii_word_sys[ 7] : 32'd0;
    assign dbg_rx_mii_word8  = (MII_DEBUG != 0) ? rx_mii_word_sys[ 8] : 32'd0;
    assign dbg_rx_mii_word9  = (MII_DEBUG != 0) ? rx_mii_word_sys[ 9] : 32'd0;
    assign dbg_rx_mii_word10 = (MII_DEBUG != 0) ? rx_mii_word_sys[10] : 32'd0;
    assign dbg_rx_mii_word11 = (MII_DEBUG != 0) ? rx_mii_word_sys[11] : 32'd0;
    assign dbg_rx_mii_word12 = (MII_DEBUG != 0) ? rx_mii_word_sys[12] : 32'd0;
    assign dbg_rx_mii_word13 = (MII_DEBUG != 0) ? rx_mii_word_sys[13] : 32'd0;
    assign dbg_rx_mii_word14 = (MII_DEBUG != 0) ? rx_mii_word_sys[14] : 32'd0;
    assign dbg_rx_mii_word15 = (MII_DEBUG != 0) ? rx_mii_word_sys[15] : 32'd0;
    assign dbg_rx_replay_last_len = (MII_DEBUG != 0) ? rx_replay_last_len_sys : 32'd0;
    assign dbg_rx_replay_word0 = (MII_DEBUG != 0) ? rx_replay_word0_sys : 32'd0;
    assign dbg_rx_replay_word1 = (MII_DEBUG != 0) ? rx_replay_word1_sys : 32'd0;
    assign dbg_rx_replay_word2 = (MII_DEBUG != 0) ? rx_replay_word2_sys : 32'd0;
    assign dbg_rx_replay_word3 = (MII_DEBUG != 0) ? rx_replay_word3_sys : 32'd0;
    assign dbg_rx_replay_eof_count = (MII_DEBUG != 0) ? rx_replay_eof_count_sys : 32'd0;

    assign rx_mem_rd_en = (rx_replay_state == RX_REPLAY_PRIME) ||
                          ((rx_replay_state == RX_REPLAY_WAIT) &&
                           (rx_replay_len > 16'd1)) ||
                          ((rx_replay_state == RX_REPLAY_SEND) &&
                           ((rx_replay_index + 16'd2) < rx_replay_len));
    assign rx_mem_rd_addr_reg =
        (rx_replay_state == RX_REPLAY_PRIME) ? 12'd0 :
        (rx_replay_state == RX_REPLAY_WAIT)  ? 12'd1 :
                                               rx_mem_rd_addr[11:0];

`ifdef XILINX_7SERIES
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(12),
        .ADDR_WIDTH_B(12),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(9),
        .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(9 * 4096),
        .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(9),
        .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"),
        .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(9),
        .WRITE_MODE_B("read_first")
    ) u_rx_frame_mem (
        .sleep(1'b0),
        .clka(clk),
        .ena(rx_mem_wr_en),
        .wea(1'b1),
        .addra(rx_mem_wr_addr),
        .dina(rx_mem_wr_data),
        .injectsbiterra(1'b0),
        .injectdbiterra(1'b0),
        .clkb(clk),
        .rstb(1'b0),
        .enb(rx_mem_rd_en),
        .regceb(1'b1),
        .addrb(rx_mem_rd_addr_reg),
        .doutb(rx_frame_mem_dout),
        .sbiterrb(),
        .dbiterrb()
    );
`else
    (* ram_style = "block" *) reg [8:0] rx_frame_mem [0:4095];
    reg [8:0] rx_frame_mem_dout_r;
    assign rx_frame_mem_dout = rx_frame_mem_dout_r;

    always @(posedge clk) begin
        if (rx_mem_wr_en)
            rx_frame_mem[rx_mem_wr_addr] <= rx_mem_wr_data;
        if (rx_mem_rd_en)
            rx_frame_mem_dout_r <= rx_frame_mem[rx_mem_rd_addr_reg];
    end
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if (MII_DEBUG != 0) begin
                rx_full_frame_s1 <= 1'b0;
                rx_full_frame_s2 <= 1'b0;
                rx_full_frame_s3 <= 1'b0;
                rx_full_write_s1 <= 1'b0;
                rx_full_write_s2 <= 1'b0;
                rx_full_write_s3 <= 1'b0;
                rx_overflow_s1 <= 1'b0;
                rx_overflow_s2 <= 1'b0;
                rx_overflow_s3 <= 1'b0;
                rx_mii_frame_s1 <= 1'b0;
                rx_mii_frame_s2 <= 1'b0;
                rx_mii_frame_s3 <= 1'b0;
                rx_wr_level_max_s1 <= 13'd0;
                rx_wr_level_max_s2 <= 13'd0;
                rx_fifo_full_frames_sys <= 32'd0;
                rx_fifo_full_writes_sys <= 32'd0;
                rx_fifo_overflow_pulses_sys <= 32'd0;
                rx_fifo_wr_level_max_sys <= 32'd0;
                rx_mii_last_len_sys <= 32'd0;
                for (rxsi = 0; rxsi < 16; rxsi = rxsi + 1)
                    rx_mii_word_sys[rxsi] <= 32'd0;
            end
        end else begin
            if (MII_DEBUG != 0) begin
                rx_full_frame_s1 <= rx_fifo_full_frame_toggle;
                rx_full_frame_s2 <= rx_full_frame_s1;
                rx_full_frame_s3 <= rx_full_frame_s2;
                rx_full_write_s1 <= rx_fifo_full_write_toggle;
                rx_full_write_s2 <= rx_full_write_s1;
                rx_full_write_s3 <= rx_full_write_s2;
                rx_overflow_s1 <= rx_fifo_overflow_toggle;
                rx_overflow_s2 <= rx_overflow_s1;
                rx_overflow_s3 <= rx_overflow_s2;
                rx_mii_frame_s1 <= rx_mii_frame_toggle;
                rx_mii_frame_s2 <= rx_mii_frame_s1;
                rx_mii_frame_s3 <= rx_mii_frame_s2;
                rx_wr_level_max_s1 <= rx_fifo_wr_level_max_rxclk;
                rx_wr_level_max_s2 <= rx_wr_level_max_s1;

                if (rx_full_frame_s2 != rx_full_frame_s3)
                    rx_fifo_full_frames_sys <= rx_fifo_full_frames_sys + 1'b1;
                if (rx_full_write_s2 != rx_full_write_s3)
                    rx_fifo_full_writes_sys <= rx_fifo_full_writes_sys + 1'b1;
                if (rx_overflow_s2 != rx_overflow_s3)
                    rx_fifo_overflow_pulses_sys <= rx_fifo_overflow_pulses_sys + 1'b1;
                if (rx_wr_level_max_s2 > rx_fifo_wr_level_max_sys[12:0])
                    rx_fifo_wr_level_max_sys <= {19'd0, rx_wr_level_max_s2};
                if (rx_mii_frame_s2 != rx_mii_frame_s3) begin
                    rx_mii_last_len_sys <= {16'd0, rx_mii_last_len_rxclk};
                    for (rxsi = 0; rxsi < 16; rxsi = rxsi + 1)
                        rx_mii_word_sys[rxsi] <= rx_mii_word_rxclk[rxsi];
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gmii_rxd            <= 8'd0;
            gmii_rx_dv          <= 1'b0;
            gmii_rx_er          <= 1'b0;
            rx_rd_en            <= 1'b0;
            rx_mem_wr_en        <= 1'b0;
            rx_mem_wr_addr      <= 12'd0;
            rx_mem_wr_data      <= 9'd0;
            rx_replay_state     <= RX_REPLAY_IDLE;
            rx_load_wait        <= 1'b0;
            rx_load_count       <= 16'd0;
            rx_replay_len       <= 16'd0;
            rx_replay_index     <= 16'd0;
            rx_mem_rd_addr      <= 16'd0;
            rx_mem_rd_data      <= 9'd0;
            rx_frame_done_pulse <= 1'b0;
            if (MII_DEBUG != 0) begin
                rx_replay_gap_frames_sys <= 32'd0;
                rx_replay_gap_cycles_sys <= 32'd0;
                rx_replay_gap_byte_max_sys <= 32'd0;
                rx_replay_byte_count <= 16'd0;
                rx_replay_gap_seen <= 1'b0;
                rx_replay_last_len_sys <= 32'd0;
                rx_replay_word0_sys <= 32'd0;
                rx_replay_word1_sys <= 32'd0;
                rx_replay_word2_sys <= 32'd0;
                rx_replay_word3_sys <= 32'd0;
                rx_replay_eof_count_sys <= 32'd0;
            end
        end else begin
            rx_rd_en            <= 1'b0;
            rx_mem_wr_en        <= 1'b0;
            gmii_rx_dv          <= 1'b0;
            gmii_rx_er          <= 1'b0;
            rx_frame_done_pulse <= 1'b0;

            case (rx_replay_state)
                RX_REPLAY_IDLE: begin
                    rx_load_wait <= 1'b0;
                    rx_load_count <= 16'd0;
                    if (MII_DEBUG != 0) begin
                        rx_replay_byte_count <= 16'd0;
                        rx_replay_gap_seen <= 1'b0;
                    end
                    if (rx_frame_ready && rx_rd_word_valid) begin
                        rx_replay_state <= RX_REPLAY_LOAD;
                    end
                end

                RX_REPLAY_LOAD: begin
                    if (rx_load_wait) begin
                        rx_load_wait <= 1'b0;
                    end else if (rx_rd_word_valid) begin
                        rx_rd_en <= 1'b1;
                        rx_load_wait <= 1'b1;
                        if (rx_rd_data[9]) begin
                            rx_frame_done_pulse <= 1'b1;
                            rx_replay_len <= rx_load_count;
                            if (MII_DEBUG != 0) begin
                                rx_replay_last_len_sys <= {16'd0, rx_load_count};
                                rx_replay_eof_count_sys <= rx_replay_eof_count_sys + 1'b1;
                                rx_replay_byte_count <= 16'd0;
                                rx_replay_gap_seen <= 1'b0;
                            end
                            rx_mem_rd_addr <= 16'd0;
                            rx_replay_index <= 16'd0;
                            rx_replay_state <= (rx_load_count != 16'd0) ?
                                               RX_REPLAY_PRIME : RX_REPLAY_IDLE;
                        end else begin
                            rx_mem_wr_en <= 1'b1;
                            rx_mem_wr_addr <= rx_load_count[11:0];
                            rx_mem_wr_data <= {rx_rd_data[8], rx_rd_data[7:0]};
                            rx_load_count <= rx_load_count + 1'b1;
                        end
                    end else begin
                        if (MII_DEBUG != 0) begin
                            rx_replay_gap_cycles_sys <= rx_replay_gap_cycles_sys + 1'b1;
                            if (!rx_replay_gap_seen) begin
                                rx_replay_gap_frames_sys <= rx_replay_gap_frames_sys + 1'b1;
                                rx_replay_gap_seen <= 1'b1;
                            end
                            if ({16'd0, rx_load_count} > rx_replay_gap_byte_max_sys)
                                rx_replay_gap_byte_max_sys <= {16'd0, rx_load_count};
                        end
                    end
                end

                RX_REPLAY_PRIME: begin
                    rx_mem_rd_addr <= 16'd1;
                    rx_replay_index <= 16'd0;
                    rx_replay_state <= RX_REPLAY_WAIT;
                end

                RX_REPLAY_WAIT: begin
                    rx_mem_rd_data <= rx_frame_mem_dout;
                    if (rx_replay_len > 16'd1) begin
                        rx_mem_rd_addr <= 16'd2;
                    end
                    rx_replay_state <= RX_REPLAY_SEND;
                end

                RX_REPLAY_SEND: begin
                    gmii_rxd   <= rx_mem_rd_data[7:0];
                    gmii_rx_er <= rx_mem_rd_data[8];
                    gmii_rx_dv <= 1'b1;
                    if (MII_DEBUG != 0) begin
                        case (rx_replay_byte_count[3:0])
                            4'h0: rx_replay_word0_sys[31:24] <= rx_mem_rd_data[7:0];
                            4'h1: rx_replay_word0_sys[23:16] <= rx_mem_rd_data[7:0];
                            4'h2: rx_replay_word0_sys[15:8]  <= rx_mem_rd_data[7:0];
                            4'h3: rx_replay_word0_sys[7:0]   <= rx_mem_rd_data[7:0];
                            4'h4: rx_replay_word1_sys[31:24] <= rx_mem_rd_data[7:0];
                            4'h5: rx_replay_word1_sys[23:16] <= rx_mem_rd_data[7:0];
                            4'h6: rx_replay_word1_sys[15:8]  <= rx_mem_rd_data[7:0];
                            4'h7: rx_replay_word1_sys[7:0]   <= rx_mem_rd_data[7:0];
                            4'h8: rx_replay_word2_sys[31:24] <= rx_mem_rd_data[7:0];
                            4'h9: rx_replay_word2_sys[23:16] <= rx_mem_rd_data[7:0];
                            4'ha: rx_replay_word2_sys[15:8]  <= rx_mem_rd_data[7:0];
                            4'hb: rx_replay_word2_sys[7:0]   <= rx_mem_rd_data[7:0];
                            4'hc: rx_replay_word3_sys[31:24] <= rx_mem_rd_data[7:0];
                            4'hd: rx_replay_word3_sys[23:16] <= rx_mem_rd_data[7:0];
                            4'he: rx_replay_word3_sys[15:8]  <= rx_mem_rd_data[7:0];
                            4'hf: rx_replay_word3_sys[7:0]   <= rx_mem_rd_data[7:0];
                        endcase
                        rx_replay_byte_count <= rx_replay_byte_count + 1'b1;
                    end

                    if ((rx_replay_index + 1'b1) >= rx_replay_len) begin
                        rx_replay_state <= RX_REPLAY_IDLE;
                    end else begin
                        rx_mem_rd_data <= rx_frame_mem_dout;
                        if ((rx_replay_index + 16'd2) < rx_replay_len) begin
                            rx_mem_rd_addr <= rx_mem_rd_addr + 1'b1;
                        end
                        rx_replay_index <= rx_replay_index + 1'b1;
                    end
                end

                default: rx_replay_state <= RX_REPLAY_IDLE;
            endcase
        end
    end

    // =========================================================================
    // TX path: GMII -> data FIFO with EOF sideband -> MII
    // =========================================================================
    reg tx_en_d1;
    reg tx_er_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_en_d1 <= 1'b0;
            tx_er_d1 <= 1'b0;
        end else begin
            tx_en_d1 <= gmii_tx_en;
            tx_er_d1 <= gmii_tx_er;
        end
    end
    wire tx_en_fall  = tx_en_d1 && !gmii_tx_en;
    wire tx_er_rise  = gmii_tx_er && !tx_er_d1;

    // gmii_tx_er visibility. The MII output stage discards gmii_tx_er today -
    // these counters surface that fact without changing TX semantics so a
    // store-and-forward upstream (or a later mii_if-side discard) can be
    // validated against hardware.
    reg [31:0] tx_er_pulses_r;
    reg [31:0] tx_er_frames_r;
    reg        tx_er_seen_this_frame;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if (MII_DEBUG != 0) begin
                tx_er_pulses_r        <= 32'd0;
                tx_er_frames_r        <= 32'd0;
                tx_er_seen_this_frame <= 1'b0;
            end
        end else begin
            if (MII_DEBUG != 0) begin
                if (tx_er_rise && gmii_tx_en)
                    tx_er_pulses_r <= tx_er_pulses_r + 32'd1;
                if (gmii_tx_en && gmii_tx_er)
                    tx_er_seen_this_frame <= 1'b1;
                if (tx_en_fall) begin
                    if (tx_er_seen_this_frame)
                        tx_er_frames_r <= tx_er_frames_r + 32'd1;
                    tx_er_seen_this_frame <= 1'b0;
                end
            end
        end
    end
    assign dbg_tx_er_pulses = (MII_DEBUG != 0) ? tx_er_pulses_r : 32'd0;
    assign dbg_tx_er_frames = (MII_DEBUG != 0) ? tx_er_frames_r : 32'd0;

    reg [11:0] tx_frame_len_wr;
    reg [11:0] tx_len_wr_data;
    reg        tx_len_wr_en;
    reg [7:0]  tx_data_d1;
    reg        tx_wr_valid_d1;

    wire [8:0] tx_wr_data = {tx_en_fall, tx_data_d1};
    wire       tx_wr_en   = tx_wr_valid_d1;
    wire       tx_wr_accept = tx_wr_en && !tx_wr_rst_busy && !tx_wr_full;
    wire       tx_eof_wr_accept = tx_wr_accept && tx_wr_data[8];
    wire [8:0] tx_rd_data;
    wire       tx_rd_empty;
    wire       tx_rd_valid;
    wire       tx_rd_word_valid;
    reg        tx_rd_en;
    wire       tx_wr_rst_busy;
    wire       tx_rd_rst_busy;
    wire [12:0] tx_wr_data_count;
    wire        tx_wr_full;

    reg [12:0] tx_fifo_count;
`ifndef XILINX_7SERIES
    reg tx_rd_toggle;
    reg tx_rd_sync1, tx_rd_sync2, tx_rd_sync3;
    wire tx_rd_pulse_sys = tx_rd_sync2 ^ tx_rd_sync3;
`endif
    localparam [12:0] TX_FIFO_DEPTH      = 13'd4096;
    // Headroom must cover (frame_bytes_written - frame_bytes_drained) during
    // a single eth_mac_tx frame *plus* CDC slop on wr_data_count. With
    // sys_clk=100MHz writing at 1B/cycle and MII=12.5MB/s draining, a
    // 1518-byte frame nets ~1340 bytes of growth - but mii_if also sits in
    // a 40-cycle IFG between drained frames where no drain occurs, so the
    // worst-case growth approaches 1530. Reserve 3072 bytes of headroom to
    // absorb wr_data_count CDC latency and keep the FIFO out of drop
    // territory during sustained line-rate bursts.
    localparam [12:0] TX_MAX_FRAME_BYTES = 13'd3072;
    localparam [12:0] TX_START_LIMIT     = TX_FIFO_DEPTH - TX_MAX_FRAME_BYTES;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_frame_len_wr <= 12'd0;
            tx_len_wr_data  <= 12'd0;
            tx_len_wr_en    <= 1'b0;
            tx_data_d1      <= 8'd0;
            tx_wr_valid_d1  <= 1'b0;
            tx_fifo_count   <= 13'd0;
`ifndef XILINX_7SERIES
            tx_rd_sync1     <= 1'b0;
            tx_rd_sync2     <= 1'b0;
            tx_rd_sync3     <= 1'b0;
`endif
        end else begin
            tx_len_wr_en <= 1'b0;
            tx_data_d1 <= gmii_txd;
            tx_wr_valid_d1 <= gmii_tx_en;
`ifndef XILINX_7SERIES
            tx_rd_sync1 <= tx_rd_toggle;
            tx_rd_sync2 <= tx_rd_sync1;
            tx_rd_sync3 <= tx_rd_sync2;
`endif

            if (gmii_tx_en && !tx_wr_full)
                tx_frame_len_wr <= tx_frame_len_wr + 12'd1;

            if (tx_en_fall) begin
                tx_len_wr_data  <= tx_frame_len_wr;
                tx_len_wr_en    <= 1'b1;
                tx_frame_len_wr <= 12'd0;
            end

`ifndef XILINX_7SERIES
            case ({tx_wr_accept, tx_rd_pulse_sys})
                2'b10: if (tx_fifo_count < TX_FIFO_DEPTH)
                           tx_fifo_count <= tx_fifo_count + 13'd1;
                2'b01: if (tx_fifo_count > 13'd0)
                           tx_fifo_count <= tx_fifo_count - 13'd1;
                2'b11: ;
                default: ;
            endcase
`endif
        end
    end

`ifdef XILINX_7SERIES
    assign tx_fifo_level = tx_wr_data_count;
    assign tx_busy       = (tx_frames_pending_r >= 3'd2) ||
                           (tx_wr_data_count > TX_START_LIMIT);
`else
    assign tx_fifo_level = tx_fifo_count;
    assign tx_busy       = (tx_frames_pending_r >= 3'd2) ||
                           (tx_fifo_count > TX_START_LIMIT);
`endif

    // Debug output assigns
    assign dbg_tx_wr_en           = (MII_DEBUG != 0) ? (tx_wr_en && !tx_wr_full) : 1'b0;
    assign dbg_tx_len_wr_en       = (MII_DEBUG != 0) ? tx_len_wr_en : 1'b0;
    assign dbg_tx_wr_full         = (MII_DEBUG != 0) ? tx_wr_full : 1'b0;
    assign dbg_tx_wr_rst_busy_out = (MII_DEBUG != 0) ? tx_wr_rst_busy : 1'b0;
    assign dbg_tx_rd_en           = (MII_DEBUG != 0) ? tx_rd_en : 1'b0;
    assign dbg_tx_frame_loaded    = (MII_DEBUG != 0) ? tx_frame_loaded : 1'b0;
    assign dbg_last_tx_len_wr     = (MII_DEBUG != 0) ? tx_len_wr_data : 12'd0;

    // Frame counters (sys_clk domain)
    reg [11:0] tx_frames_queued_r;
    reg [11:0] tx_frames_drained_r;
    reg [2:0]  tx_frames_pending_r;
    reg [3:0]  tx_frame_wr_count_bin;
    reg [3:0]  tx_frame_wr_count_gray;
    (* ASYNC_REG = "TRUE" *) reg [3:0] tx_frame_wr_count_s1;
    (* ASYNC_REG = "TRUE" *) reg [3:0] tx_frame_wr_count_s2;
    (* ASYNC_REG = "TRUE" *) reg [3:0] tx_frame_wr_count_s3;
    reg [3:0]  tx_frame_rd_count_bin;
    // Drain counter CDC: toggle in mii_tx_clk, sync to sys_clk
    reg        drain_toggle;
    reg        drain_sync1, drain_sync2, drain_sync3;
    wire       drain_pulse = drain_sync2 ^ drain_sync3;
    wire       tx_len_write_ok = tx_eof_wr_accept;

    assign dbg_tx_frames_queued  = (MII_DEBUG != 0) ? tx_frames_queued_r : 12'd0;
    assign dbg_tx_frames_drained = (MII_DEBUG != 0) ? tx_frames_drained_r : 12'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_frames_queued_r <= 12'd0;
            tx_frames_drained_r <= 12'd0;
            tx_frames_pending_r <= 3'd0;
            tx_frame_wr_count_bin <= 4'd0;
            tx_frame_wr_count_gray <= 4'd0;
            drain_sync1 <= 1'b0;
            drain_sync2 <= 1'b0;
            drain_sync3 <= 1'b0;
        end else begin
            drain_sync1 <= drain_toggle;
            drain_sync2 <= drain_sync1;
            drain_sync3 <= drain_sync2;
            if (tx_len_write_ok) begin
                tx_frames_queued_r <= tx_frames_queued_r + 12'd1;
                tx_frame_wr_count_bin <= tx_frame_wr_count_bin + 4'd1;
                tx_frame_wr_count_gray <= (tx_frame_wr_count_bin + 4'd1) ^
                                           ((tx_frame_wr_count_bin + 4'd1) >> 1);
            end
            if (drain_pulse)
                tx_frames_drained_r <= tx_frames_drained_r + 12'd1;

            case ({tx_len_write_ok, drain_pulse})
                2'b10: if (tx_frames_pending_r != 3'd7)
                           tx_frames_pending_r <= tx_frames_pending_r + 3'd1;
                2'b01: if (tx_frames_pending_r != 3'd0)
                           tx_frames_pending_r <= tx_frames_pending_r - 3'd1;
                default: ;
            endcase
        end
    end

    always @(posedge mii_tx_clk or negedge tx_rst_n_s2) begin
        if (!tx_rst_n_s2) begin
            tx_frame_wr_count_s1 <= 4'd0;
            tx_frame_wr_count_s2 <= 4'd0;
            tx_frame_wr_count_s3 <= 4'd0;
        end else begin
            tx_frame_wr_count_s1 <= tx_frame_wr_count_gray;
            tx_frame_wr_count_s2 <= tx_frame_wr_count_s1;
            tx_frame_wr_count_s3 <= tx_frame_wr_count_s2;
        end
    end

    wire [3:0] tx_frame_wr_count_mii = gray4_to_bin(tx_frame_wr_count_s3);
    wire       tx_frame_pending_mii = (tx_frame_wr_count_mii != tx_frame_rd_count_bin);

    assign dbg_tx_fifo_empty     = (MII_DEBUG != 0) ? tx_rd_empty : 1'b0;
    assign dbg_rx_prog_empty     = (MII_DEBUG != 0) ? rx_prog_empty : 1'b0;
    assign dbg_rx_rd_empty       = (MII_DEBUG != 0) ? rx_rd_empty : 1'b0;
    assign dbg_rx_reading        = (MII_DEBUG != 0) ? (rx_replay_state != RX_REPLAY_IDLE) : 1'b0;
    assign dbg_rx_frames_pending = (MII_DEBUG != 0) ? {1'b0, rx_frame_ready} : 2'd0;

`ifdef XILINX_7SERIES
    xpm_fifo_async #(
        .FIFO_WRITE_DEPTH(4096),
        .WRITE_DATA_WIDTH(9),
        .READ_DATA_WIDTH(9),
        .READ_MODE("FWFT"),
        .FIFO_READ_LATENCY(0),
        .CDC_SYNC_STAGES(3),
        .DOUT_RESET_VALUE("0"),
        .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(10),
        .PROG_FULL_THRESH(10),
        .RD_DATA_COUNT_WIDTH(1),
        .WR_DATA_COUNT_WIDTH(13),
        .USE_ADV_FEATURES("0004"),
        .WAKEUP_TIME(0)
    ) u_tx_fifo (
        .wr_clk        (clk),
        .wr_en         (tx_wr_accept),
        .din           (tx_wr_data),
        .full          (tx_wr_full),
        .wr_rst_busy   (tx_wr_rst_busy),
        .rd_clk        (mii_tx_clk),
        .rd_en         (tx_rd_en && !tx_rd_rst_busy),
        .dout          (tx_rd_data),
        .empty         (tx_rd_empty),
        .rd_rst_busy   (tx_rd_rst_busy),
        .rst           (~rst_n),
        .sleep         (1'b0),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0),
        .sbiterr       (),
        .dbiterr       (),
        .overflow      (),
        .underflow     (),
        .prog_full     (),
        .prog_empty    (),
        .almost_full   (),
        .almost_empty  (),
        .wr_data_count (tx_wr_data_count),
        .rd_data_count (),
        .data_valid    (tx_rd_valid),
        .wr_ack        ()
    );
    assign tx_rd_word_valid = !tx_rd_empty && !tx_rd_rst_busy;
`else
    assign tx_wr_rst_busy   = 1'b0;
    assign tx_rd_rst_busy   = 1'b0;
    assign tx_wr_data_count = tx_fifo_count;
    assign tx_rd_valid      = !tx_rd_empty;
    assign tx_rd_word_valid = !tx_rd_empty;
    async_fifo #(.DATA_WIDTH(9), .ADDR_WIDTH(12)) u_tx_fifo (
        .wr_clk  (clk),
        .wr_rst_n(rst_n),
        .wr_data (tx_wr_data),
        .wr_en   (tx_wr_accept),
        .wr_full (tx_wr_full),
        .rd_clk  (mii_tx_clk),
        .rd_rst_n(tx_rst_n_s2),
        .rd_data (tx_rd_data),
        .rd_en   (tx_rd_en),
        .rd_empty(tx_rd_empty)
    );
`endif

    localparam [1:0]
        TX_IDLE = 2'd0,
        TX_LOW  = 2'd1,
        TX_HIGH = 2'd2;

    reg [1:0]  tx_st;
    reg [7:0]  tx_byte;
    reg        tx_byte_last;

    // Internal MII TX signals (used by state machine + debug taps)
    reg [3:0]  mii_txd_int;
    reg        mii_tx_en_int;

    // Dedicated IOB output registers - fanout=1, drives pad only
    (* IOB = "TRUE" *) reg [3:0] mii_txd_iob;
    (* IOB = "TRUE" *) reg       mii_tx_en_iob;

    assign mii_txd   = mii_txd_iob;
    assign mii_tx_en = mii_tx_en_iob;
    assign dbg_mii_txd_pre_iob = (MII_DEBUG != 0) ? mii_txd_int : 4'd0;
    assign dbg_mii_tx_en_pre_iob = (MII_DEBUG != 0) ? mii_tx_en_int : 1'b0;

    // IOB register stage: copies internal to pad on every mii_tx_clk
    always @(posedge mii_tx_clk) begin
        if (!tx_rst_n_s2) begin
            mii_txd_iob   <= 4'd0;
            mii_tx_en_iob <= 1'b0;
        end else begin
            mii_txd_iob   <= mii_txd_int;
            mii_tx_en_iob <= mii_tx_en_int;
        end
    end
    reg [5:0]  tx_start_delay;
    reg        tx_frame_loaded;

    always @(posedge mii_tx_clk) begin
        if (!tx_rst_n_s2) begin
            tx_st               <= TX_IDLE;
            tx_byte             <= 8'd0;
            mii_txd_int         <= 4'd0;
            mii_tx_en_int       <= 1'b0;
            tx_rd_en            <= 1'b0;
            tx_byte_last        <= 1'b0;
            tx_start_delay      <= 6'd0;
            tx_frame_loaded     <= 1'b0;
            tx_frame_rd_count_bin <= 4'd0;
            drain_toggle        <= 1'b0;
`ifndef XILINX_7SERIES
            tx_rd_toggle        <= 1'b0;
`endif
        end else begin
            tx_rd_en     <= 1'b0;

            case (tx_st)
                TX_IDLE: begin
                    mii_tx_en_int <= 1'b0;
                    mii_txd_int   <= 4'd0;
                    if (!tx_frame_loaded && tx_frame_pending_mii) begin
                        tx_start_delay      <= 6'd40;
                        tx_frame_loaded     <= 1'b1;
                    end else if (tx_frame_loaded) begin
                        if (tx_start_delay != 6'd0) begin
                            tx_start_delay <= tx_start_delay - 6'd1;
                        end else if (tx_rd_word_valid) begin
                            tx_byte             <= tx_rd_data[7:0];
                            tx_byte_last        <= tx_rd_data[8];
                            tx_rd_en            <= 1'b1;
                            tx_st               <= TX_LOW;
`ifndef XILINX_7SERIES
                            tx_rd_toggle        <= ~tx_rd_toggle;
`endif
                        end
                    end
                end

                TX_LOW: begin
                    mii_txd_int   <= tx_byte[3:0];
                    mii_tx_en_int <= 1'b1;
                    tx_st     <= TX_HIGH;
                end

                TX_HIGH: begin
                    mii_txd_int   <= tx_byte[7:4];
                    mii_tx_en_int <= 1'b1;
                    if (tx_byte_last) begin
                        tx_frame_loaded <= 1'b0;
                        tx_st <= TX_IDLE;
                        tx_frame_rd_count_bin <= tx_frame_rd_count_bin + 4'd1;
                        drain_toggle <= ~drain_toggle;
                    end else if (tx_rd_word_valid) begin
                        tx_byte             <= tx_rd_data[7:0];
                        tx_byte_last        <= tx_rd_data[8];
                        tx_rd_en            <= 1'b1;
                        tx_st               <= TX_LOW;
`ifndef XILINX_7SERIES
                        tx_rd_toggle        <= ~tx_rd_toggle;
`endif
                    end
                end

                default: tx_st <= TX_IDLE;
            endcase
        end
    end

    // =========================================================================
    // MII TX byte capture (mii_tx_clk domain)
    // Captures the first 64 bytes of every transmitted frame, overwriting on
    // each new frame so software always sees the most recent. Software should
    // poll dbg_mii_cap_done and read while it stays high.
    // =========================================================================
    reg [7:0]  mii_cap [0:63];      // captured bytes from TX data FIFO
    reg [5:0]  mii_cap_idx;
    reg [11:0] mii_cap_frame_len;   // frame length counted during TX readout
    reg        mii_cap_active;      // currently capturing
    reg        mii_cap_done;        // capture complete for the latest frame

    integer mi;
    always @(posedge mii_tx_clk) begin
        if (!tx_rst_n_s2) begin
            if (MII_DEBUG != 0) begin
                mii_cap_idx       <= 6'd0;
                mii_cap_frame_len <= 12'd0;
                mii_cap_active    <= 1'b0;
                mii_cap_done      <= 1'b0;
                for (mi = 0; mi < 64; mi = mi + 1)
                    mii_cap[mi] <= 8'd0;
            end
        end else begin
            if (MII_DEBUG != 0) begin
                // Capture bytes as they're read from data FIFO.
                if (tx_rd_en) begin
                    if (!mii_cap_active) begin
                        mii_cap_active    <= 1'b1;
                        mii_cap_done      <= 1'b0;
                        mii_cap_idx       <= 6'd0;
                        mii_cap_frame_len <= 12'd1;
                        mii_cap[0]        <= tx_rd_data[7:0];
                    end else begin
                        mii_cap_frame_len <= mii_cap_frame_len + 12'd1;
                        if (mii_cap_idx < 6'd63) begin
                            mii_cap[mii_cap_idx + 6'd1] <= tx_rd_data[7:0];
                        end
                        mii_cap_idx <= mii_cap_idx + 6'd1;
                    end
                    if (tx_rd_data[8]) begin
                        mii_cap_active <= 1'b0;
                        mii_cap_done   <= 1'b1;
                    end
                end
            end
        end
    end

    // CDC: sync mii_cap_done to sys_clk domain
    reg mii_cap_done_s1, mii_cap_done_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if (MII_DEBUG != 0) begin
                mii_cap_done_s1 <= 1'b0;
                mii_cap_done_s2 <= 1'b0;
            end
        end else begin
            if (MII_DEBUG != 0) begin
                mii_cap_done_s1 <= mii_cap_done;
                mii_cap_done_s2 <= mii_cap_done_s1;
            end
        end
    end

    // Debug assigns for MII capture (stable after mii_cap_done_s2)
    assign dbg_mii_cap_done      = (MII_DEBUG != 0) ? mii_cap_done_s2 : 1'b0;
    assign dbg_mii_cap_frame_len = (MII_DEBUG != 0) ? mii_cap_frame_len : 12'd0;
    assign dbg_mii_cap_word0     = (MII_DEBUG != 0) ? {mii_cap[ 0], mii_cap[ 1], mii_cap[ 2], mii_cap[ 3]} : 32'd0;
    assign dbg_mii_cap_word1     = (MII_DEBUG != 0) ? {mii_cap[ 4], mii_cap[ 5], mii_cap[ 6], mii_cap[ 7]} : 32'd0;
    assign dbg_mii_cap_word2     = (MII_DEBUG != 0) ? {mii_cap[ 8], mii_cap[ 9], mii_cap[10], mii_cap[11]} : 32'd0;
    assign dbg_mii_cap_word3     = (MII_DEBUG != 0) ? {mii_cap[12], mii_cap[13], mii_cap[14], mii_cap[15]} : 32'd0;
    assign dbg_mii_cap_word4     = (MII_DEBUG != 0) ? {mii_cap[16], mii_cap[17], mii_cap[18], mii_cap[19]} : 32'd0;
    assign dbg_mii_cap_word5     = (MII_DEBUG != 0) ? {mii_cap[20], mii_cap[21], mii_cap[22], mii_cap[23]} : 32'd0;
    assign dbg_mii_cap_word6     = (MII_DEBUG != 0) ? {mii_cap[24], mii_cap[25], mii_cap[26], mii_cap[27]} : 32'd0;
    assign dbg_mii_cap_word7     = (MII_DEBUG != 0) ? {mii_cap[28], mii_cap[29], mii_cap[30], mii_cap[31]} : 32'd0;
    assign dbg_mii_cap_word8     = (MII_DEBUG != 0) ? {mii_cap[32], mii_cap[33], mii_cap[34], mii_cap[35]} : 32'd0;
    assign dbg_mii_cap_word9     = (MII_DEBUG != 0) ? {mii_cap[36], mii_cap[37], mii_cap[38], mii_cap[39]} : 32'd0;
    assign dbg_mii_cap_word10    = (MII_DEBUG != 0) ? {mii_cap[40], mii_cap[41], mii_cap[42], mii_cap[43]} : 32'd0;
    assign dbg_mii_cap_word11    = (MII_DEBUG != 0) ? {mii_cap[44], mii_cap[45], mii_cap[46], mii_cap[47]} : 32'd0;
    assign dbg_mii_cap_word12    = (MII_DEBUG != 0) ? {mii_cap[48], mii_cap[49], mii_cap[50], mii_cap[51]} : 32'd0;
    assign dbg_mii_cap_word13    = (MII_DEBUG != 0) ? {mii_cap[52], mii_cap[53], mii_cap[54], mii_cap[55]} : 32'd0;
    assign dbg_mii_cap_word14    = (MII_DEBUG != 0) ? {mii_cap[56], mii_cap[57], mii_cap[58], mii_cap[59]} : 32'd0;
    assign dbg_mii_cap_word15    = (MII_DEBUG != 0) ? {mii_cap[60], mii_cap[61], mii_cap[62], mii_cap[63]} : 32'd0;

endmodule
