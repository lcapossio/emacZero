// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// mii_if.v - MII PHY Interface with Store-and-Forward CDC
// Converts between 8-bit GMII (100 MHz sys_clk) and 4-bit MII (25 MHz PHY)
// Verilog 2001
// =============================================================================

module mii_if (
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
    output wire [11:0] tx_fifo_level,
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
    // MII TX byte capture (CDC'd to sys_clk)
    output wire        dbg_mii_cap_done,
    output wire [11:0] dbg_mii_cap_frame_len,
    output wire [31:0] dbg_mii_cap_word0,
    output wire [31:0] dbg_mii_cap_word1,
    output wire [31:0] dbg_mii_cap_word2,
    output wire [31:0] dbg_mii_cap_word3
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
        end else begin
            rx_wr_en <= 1'b0;
            rx_dv_d1 <= mii_rx_dv_iob;

            if (mii_rx_dv_iob) begin
                if (!rx_nib_sel) begin
                    rx_nib_low <= mii_rxd_iob;
                    rx_er_low  <= mii_rx_er_iob;
                    rx_nib_sel <= 1'b1;
                end else begin
                    rx_wr_data <= {1'b0, rx_er_low | mii_rx_er_iob, mii_rxd_iob, rx_nib_low};
                    rx_wr_en   <= 1'b1;
                    rx_nib_sel <= 1'b0;
                end
            end else begin
                rx_nib_sel <= 1'b0;
                if (rx_dv_d1) begin
                    rx_wr_data <= {1'b1, 1'b0, 8'h00};
                    rx_wr_en   <= 1'b1;
                end
            end
        end
    end

    (* keep = "true" *) reg rx_frame_toggle;
    always @(posedge mii_rx_clk or negedge rx_rst_n_s2) begin
        if (!rx_rst_n_s2)
            rx_frame_toggle <= 1'b0;
        else if (rx_wr_en && rx_wr_data[9])
            rx_frame_toggle <= ~rx_frame_toggle;
    end

    wire [9:0] rx_rd_data;
    wire       rx_rd_empty;
    reg        rx_rd_en;
    wire       rx_wr_rst_busy;
    wire       rx_rd_rst_busy;
    wire       rx_prog_empty;

`ifdef SYNTHESIS
    xpm_fifo_async #(
        .FIFO_WRITE_DEPTH(2048),
        .WRITE_DATA_WIDTH(10),
        .READ_DATA_WIDTH(10),
        .READ_MODE("FWFT"),
        .FIFO_READ_LATENCY(0),
        .CDC_SYNC_STAGES(3),
        .DOUT_RESET_VALUE("0"),
        .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(64),
        .PROG_FULL_THRESH(10),
        .RD_DATA_COUNT_WIDTH(11),
        .WR_DATA_COUNT_WIDTH(11),
        .USE_ADV_FEATURES("0200"),
        .WAKEUP_TIME(0)
    ) u_rx_fifo (
        .wr_clk        (mii_rx_clk),
        .wr_en         (rx_wr_en && !rx_wr_rst_busy),
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
        .overflow      (),
        .underflow     (),
        .prog_full     (),
        .prog_empty    (rx_prog_empty),
        .almost_full   (),
        .almost_empty  (),
        .wr_data_count (),
        .rd_data_count (),
        .data_valid    (),
        .wr_ack        ()
    );
`else
    assign rx_prog_empty = 1'b1;
    assign rx_wr_rst_busy = 1'b0;
    assign rx_rd_rst_busy = 1'b0;
    async_fifo #(.DATA_WIDTH(10), .ADDR_WIDTH(11)) u_rx_fifo (
        .wr_clk  (mii_rx_clk),
        .wr_rst_n(rx_rst_n_s2),
        .wr_data (rx_wr_data),
        .wr_en   (rx_wr_en && !rx_wr_full),
        .wr_full (rx_wr_full),
        .rd_clk  (clk),
        .rd_rst_n(rst_n),
        .rd_data (rx_rd_data),
        .rd_en   (rx_rd_en),
        .rd_empty(rx_rd_empty)
    );
`endif

    reg        rx_reading;
    (* ASYNC_REG = "TRUE" *) reg rx_toggle_s1, rx_toggle_s2, rx_toggle_s3;
    reg [7:0]  rx_avail_delay;
    reg [3:0]  rx_frames_pending;
    reg        rx_frame_done_pulse;

    wire rx_frame_avail = (rx_toggle_s2 != rx_toggle_s3);
    wire rx_frame_avail_d = rx_avail_delay[7];
    wire rx_frame_ready = (rx_frames_pending > 0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_toggle_s1 <= 1'b0;
            rx_toggle_s2 <= 1'b0;
            rx_toggle_s3 <= 1'b0;
            rx_avail_delay <= 8'd0;
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gmii_rxd            <= 8'd0;
            gmii_rx_dv          <= 1'b0;
            gmii_rx_er          <= 1'b0;
            rx_rd_en            <= 1'b0;
            rx_reading          <= 1'b0;
            rx_frame_done_pulse <= 1'b0;
        end else begin
            rx_rd_en            <= 1'b0;
            gmii_rx_dv          <= 1'b0;
            gmii_rx_er          <= 1'b0;
            rx_frame_done_pulse <= 1'b0;

            if (rx_reading) begin
                if (!rx_rd_empty) begin
                    if (rx_rd_data[9]) begin
                        rx_rd_en            <= 1'b1;
                        rx_reading          <= 1'b0;
                        rx_frame_done_pulse <= 1'b1;
                    end else begin
                        gmii_rxd   <= rx_rd_data[7:0];
                        gmii_rx_dv <= 1'b1;
                        gmii_rx_er <= rx_rd_data[8];
                        rx_rd_en   <= 1'b1;
                    end
                end else if (!rx_frame_ready) begin
                    rx_reading <= 1'b0;
                end
            end else if (rx_frame_ready && !rx_rd_empty) begin
                rx_reading <= 1'b1;
            end
        end
    end

    // =========================================================================
    // TX path: GMII -> data FIFO + frame length FIFO -> MII
    // =========================================================================
    reg tx_en_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tx_en_d1 <= 1'b0;
        else        tx_en_d1 <= gmii_tx_en;
    end
    wire tx_en_fall = tx_en_d1 && !gmii_tx_en;

    reg [11:0] tx_frame_len_wr;
    reg [11:0] tx_len_wr_data;
    reg        tx_len_wr_en;

    wire [7:0] tx_wr_data = gmii_txd;
    wire       tx_wr_en   = gmii_tx_en;
    wire [7:0] tx_rd_data;
    wire       tx_rd_empty;
    reg        tx_rd_en;
    wire       tx_wr_rst_busy;
    wire       tx_rd_rst_busy;
    wire [11:0] tx_wr_data_count;
    wire        tx_wr_full;

    wire [11:0] tx_len_rd_data;
    wire        tx_len_rd_empty;
    wire        tx_len_wr_full;
    reg         tx_len_rd_en;

    reg [11:0] tx_fifo_count;
`ifndef SYNTHESIS
    reg tx_rd_toggle;
    reg tx_rd_sync1, tx_rd_sync2, tx_rd_sync3;
    wire tx_rd_pulse_sys = tx_rd_sync2 ^ tx_rd_sync3;
`endif
    localparam [12:0] TX_FIFO_DEPTH      = 13'd4096;
    // Headroom must cover (frame_bytes_written - frame_bytes_drained) during
    // a single eth_mac_tx frame *plus* CDC slop on wr_data_count. With
    // sys_clk=100MHz writing at 1B/cycle and MII=12.5MB/s draining, a
    // 1518-byte frame nets ~1340 bytes of growth — but mii_if also sits in
    // a 40-cycle IFG between drained frames where no drain occurs, so the
    // worst-case growth approaches 1530. Reserve 3072 bytes of headroom to
    // absorb wr_data_count CDC latency and keep the FIFO out of drop
    // territory during sustained line-rate bursts.
    localparam [11:0] TX_MAX_FRAME_BYTES = 12'd3072;
    localparam [11:0] TX_START_LIMIT     = TX_FIFO_DEPTH - TX_MAX_FRAME_BYTES;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_frame_len_wr <= 12'd0;
            tx_len_wr_data  <= 12'd0;
            tx_len_wr_en    <= 1'b0;
            tx_fifo_count   <= 12'd0;
`ifndef SYNTHESIS
            tx_rd_sync1     <= 1'b0;
            tx_rd_sync2     <= 1'b0;
            tx_rd_sync3     <= 1'b0;
`endif
        end else begin
            tx_len_wr_en <= 1'b0;
`ifndef SYNTHESIS
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

`ifndef SYNTHESIS
            case ({tx_wr_en && !tx_wr_full, tx_rd_pulse_sys})
                2'b10: if (tx_fifo_count < TX_FIFO_DEPTH)
                           tx_fifo_count <= tx_fifo_count + 12'd1;
                2'b01: if (tx_fifo_count > 12'd0)
                           tx_fifo_count <= tx_fifo_count - 12'd1;
                2'b11: ;
                default: ;
            endcase
`endif
        end
    end

`ifdef SYNTHESIS
    assign tx_fifo_level = tx_wr_data_count;
    assign tx_busy       = (tx_frames_pending_r >= 3'd2) ||
                           (tx_wr_data_count > TX_START_LIMIT) ||
                           tx_len_wr_full;
`else
    assign tx_fifo_level = tx_fifo_count;
    assign tx_busy       = (tx_frames_pending_r >= 3'd2) ||
                           (tx_fifo_count > TX_START_LIMIT) ||
                           tx_len_wr_full;
`endif

    // Debug output assigns
    assign dbg_tx_wr_en          = tx_wr_en && !tx_wr_full;
    assign dbg_tx_len_wr_en      = tx_len_wr_en;
    assign dbg_tx_wr_full        = tx_wr_full;
    assign dbg_tx_wr_rst_busy_out = tx_wr_rst_busy;
    assign dbg_tx_rd_en          = tx_rd_en;
    assign dbg_tx_frame_loaded   = tx_frame_loaded;
    assign dbg_last_tx_len_wr    = tx_len_wr_data;

    // Frame counters (sys_clk domain)
    reg [11:0] tx_frames_queued_r;
    reg [11:0] tx_frames_drained_r;
    reg [2:0]  tx_frames_pending_r;
    // Drain counter CDC: toggle in mii_tx_clk, sync to sys_clk
    reg        drain_toggle;
    reg        drain_sync1, drain_sync2, drain_sync3;
    wire       drain_pulse = drain_sync2 ^ drain_sync3;
    wire       tx_len_write_ok = tx_len_wr_en && !tx_len_wr_full;

    assign dbg_tx_frames_queued  = tx_frames_queued_r;
    assign dbg_tx_frames_drained = tx_frames_drained_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_frames_queued_r <= 12'd0;
            tx_frames_drained_r <= 12'd0;
            tx_frames_pending_r <= 3'd0;
            drain_sync1 <= 1'b0;
            drain_sync2 <= 1'b0;
            drain_sync3 <= 1'b0;
        end else begin
            drain_sync1 <= drain_toggle;
            drain_sync2 <= drain_sync1;
            drain_sync3 <= drain_sync2;
            if (tx_len_write_ok)
                tx_frames_queued_r <= tx_frames_queued_r + 12'd1;
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

    assign dbg_tx_fifo_empty     = tx_rd_empty;
    assign dbg_rx_prog_empty     = rx_prog_empty;
    assign dbg_rx_rd_empty       = rx_rd_empty;
    assign dbg_rx_reading        = rx_reading;
    assign dbg_rx_frames_pending = rx_frames_pending[1:0];

`ifdef SYNTHESIS
    xpm_fifo_async #(
        .FIFO_WRITE_DEPTH(4096),
        .WRITE_DATA_WIDTH(8),
        .READ_DATA_WIDTH(8),
        .READ_MODE("FWFT"),
        .FIFO_READ_LATENCY(0),
        .CDC_SYNC_STAGES(3),
        .DOUT_RESET_VALUE("0"),
        .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(10),
        .PROG_FULL_THRESH(10),
        .RD_DATA_COUNT_WIDTH(1),
        .WR_DATA_COUNT_WIDTH(12),
        .USE_ADV_FEATURES("0400"),
        .WAKEUP_TIME(0)
    ) u_tx_fifo (
        .wr_clk        (clk),
        .wr_en         (tx_wr_en && !tx_wr_rst_busy && !tx_wr_full),
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
        .data_valid    (),
        .wr_ack        ()
    );

    xpm_fifo_async #(
        .FIFO_WRITE_DEPTH(16),
        .WRITE_DATA_WIDTH(12),
        .READ_DATA_WIDTH(12),
        .READ_MODE("FWFT"),
        .FIFO_READ_LATENCY(0),
        .CDC_SYNC_STAGES(3),
        .DOUT_RESET_VALUE("0"),
        .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(5),
        .PROG_FULL_THRESH(5),
        .RD_DATA_COUNT_WIDTH(1),
        .WR_DATA_COUNT_WIDTH(5),
        .USE_ADV_FEATURES("0000"),
        .WAKEUP_TIME(0)
    ) u_tx_len_fifo (
        .wr_clk        (clk),
        .wr_en         (tx_len_wr_en && !tx_len_wr_full),
        .din           (tx_len_wr_data),
        .full          (tx_len_wr_full),
        .wr_rst_busy   (),
        .rd_clk        (mii_tx_clk),
        .rd_en         (tx_len_rd_en),
        .dout          (tx_len_rd_data),
        .empty         (tx_len_rd_empty),
        .rd_rst_busy   (),
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
        .wr_data_count (),
        .rd_data_count (),
        .data_valid    (),
        .wr_ack        ()
    );
`else
    assign tx_wr_rst_busy   = 1'b0;
    assign tx_rd_rst_busy   = 1'b0;
    assign tx_wr_data_count = tx_fifo_count;
    async_fifo #(.DATA_WIDTH(8), .ADDR_WIDTH(12)) u_tx_fifo (
        .wr_clk  (clk),
        .wr_rst_n(rst_n),
        .wr_data (tx_wr_data),
        .wr_en   (tx_wr_en && !tx_wr_full),
        .wr_full (tx_wr_full),
        .rd_clk  (mii_tx_clk),
        .rd_rst_n(tx_rst_n_s2),
        .rd_data (tx_rd_data),
        .rd_en   (tx_rd_en),
        .rd_empty(tx_rd_empty)
    );

    async_fifo #(.DATA_WIDTH(12), .ADDR_WIDTH(4)) u_tx_len_fifo (
        .wr_clk  (clk),
        .wr_rst_n(rst_n),
        .wr_data (tx_len_wr_data),
        .wr_en   (tx_len_wr_en && !tx_len_wr_full),
        .wr_full (tx_len_wr_full),
        .rd_clk  (mii_tx_clk),
        .rd_rst_n(tx_rst_n_s2),
        .rd_data (tx_len_rd_data),
        .rd_en   (tx_len_rd_en),
        .rd_empty(tx_len_rd_empty)
    );
`endif

    localparam [1:0]
        TX_IDLE = 2'd0,
        TX_LOW  = 2'd1,
        TX_HIGH = 2'd2;

    reg [1:0]  tx_st;
    reg [7:0]  tx_byte;
    reg [11:0] tx_frame_bytes_left;

    // Internal MII TX signals (used by state machine + debug taps)
    reg [3:0]  mii_txd_int;
    reg        mii_tx_en_int;

    // Dedicated IOB output registers — fanout=1, drives pad only
    (* IOB = "TRUE" *) reg [3:0] mii_txd_iob;
    (* IOB = "TRUE" *) reg       mii_tx_en_iob;

    assign mii_txd   = mii_txd_iob;
    assign mii_tx_en = mii_tx_en_iob;

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
            tx_len_rd_en        <= 1'b0;
            tx_frame_bytes_left <= 12'd0;
            tx_start_delay      <= 6'd0;
            tx_frame_loaded     <= 1'b0;
            drain_toggle        <= 1'b0;
`ifndef SYNTHESIS
            tx_rd_toggle        <= 1'b0;
`endif
        end else begin
            tx_rd_en     <= 1'b0;
            tx_len_rd_en <= 1'b0;

            case (tx_st)
                TX_IDLE: begin
                    mii_tx_en_int <= 1'b0;
                    mii_txd_int   <= 4'd0;
                    if (!tx_frame_loaded && !tx_len_rd_empty) begin
                        tx_len_rd_en        <= 1'b1;
                        tx_frame_bytes_left <= tx_len_rd_data;
                        tx_start_delay      <= 6'd40;
                        tx_frame_loaded     <= 1'b1;
                    end else if (tx_frame_loaded) begin
                        if (tx_start_delay != 6'd0) begin
                            tx_start_delay <= tx_start_delay - 6'd1;
                        end else if (tx_frame_bytes_left != 12'd0 && !tx_rd_empty) begin
                            tx_byte             <= tx_rd_data;
                            tx_rd_en            <= 1'b1;
                            tx_frame_bytes_left <= tx_frame_bytes_left - 12'd1;
                            tx_st               <= TX_LOW;
`ifndef SYNTHESIS
                            tx_rd_toggle        <= ~tx_rd_toggle;
`endif
                        end else if (tx_frame_bytes_left == 12'd0) begin
                            tx_frame_loaded <= 1'b0;
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
                    if (tx_frame_bytes_left == 12'd0) begin
                        tx_frame_loaded <= 1'b0;
                        tx_st <= TX_IDLE;
                        drain_toggle <= ~drain_toggle;
                    end else if (!tx_rd_empty) begin
                        tx_byte             <= tx_rd_data;
                        tx_rd_en            <= 1'b1;
                        tx_frame_bytes_left <= tx_frame_bytes_left - 12'd1;
                        tx_st               <= TX_LOW;
`ifndef SYNTHESIS
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
    // Captures first 32 bytes read from data FIFO for first frame with len>100.
    // Also captures the frame length from the length FIFO.
    // =========================================================================
    reg [7:0]  mii_cap [0:31];      // captured bytes (from tx_rd_data)
    reg [4:0]  mii_cap_idx;
    reg [11:0] mii_cap_frame_len;   // frame length from len FIFO
    reg        mii_cap_active;      // currently capturing
    reg        mii_cap_done;        // capture complete (stays high)
    reg [11:0] mii_cap_total_len;   // frame len being tracked

    integer mi;
    always @(posedge mii_tx_clk) begin
        if (!tx_rst_n_s2) begin
            mii_cap_idx       <= 5'd0;
            mii_cap_frame_len <= 12'd0;
            mii_cap_active    <= 1'b0;
            mii_cap_done      <= 1'b0;
            mii_cap_total_len <= 12'd0;
            for (mi = 0; mi < 32; mi = mi + 1)
                mii_cap[mi] <= 8'd0;
        end else begin
            // When a new frame is loaded from the length FIFO
            if (!tx_frame_loaded && !tx_len_rd_empty && !mii_cap_done) begin
                mii_cap_total_len <= tx_len_rd_data;
                if (tx_len_rd_data > 12'd100) begin
                    mii_cap_active    <= 1'b1;
                    mii_cap_idx       <= 5'd0;
                    mii_cap_frame_len <= tx_len_rd_data;
                end
            end

            // Capture bytes as they're read from data FIFO
            if (mii_cap_active && tx_rd_en) begin
                if (mii_cap_idx < 5'd31) begin
                    mii_cap[mii_cap_idx] <= tx_rd_data;
                    mii_cap_idx <= mii_cap_idx + 5'd1;
                end else begin
                    mii_cap[31] <= tx_rd_data;
                    mii_cap_active <= 1'b0;
                    mii_cap_done   <= 1'b1;
                end
            end

            // Also finish capture when frame ends
            if (mii_cap_active && tx_frame_bytes_left == 12'd0) begin
                mii_cap_active <= 1'b0;
                mii_cap_done   <= 1'b1;
            end
        end
    end

    // CDC: sync mii_cap_done to sys_clk domain
    reg mii_cap_done_s1, mii_cap_done_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mii_cap_done_s1 <= 1'b0;
            mii_cap_done_s2 <= 1'b0;
        end else begin
            mii_cap_done_s1 <= mii_cap_done;
            mii_cap_done_s2 <= mii_cap_done_s1;
        end
    end

    // Debug assigns for MII capture (stable after mii_cap_done_s2)
    assign dbg_mii_cap_done      = mii_cap_done_s2;
    assign dbg_mii_cap_frame_len = mii_cap_frame_len;
    assign dbg_mii_cap_word0     = {mii_cap[0],  mii_cap[1],  mii_cap[2],  mii_cap[3]};
    assign dbg_mii_cap_word1     = {mii_cap[4],  mii_cap[5],  mii_cap[6],  mii_cap[7]};
    assign dbg_mii_cap_word2     = {mii_cap[8],  mii_cap[9],  mii_cap[10], mii_cap[11]};
    assign dbg_mii_cap_word3     = {mii_cap[12], mii_cap[13], mii_cap[14], mii_cap[15]};

endmodule
