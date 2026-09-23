// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// mii_tx_saf.v - Store-and-forward MII transmit path (single FIFO)
// AXIS frame in (sys clk) -> ONE async frame FIFO {tlast,data} -> media-side
// framer (preamble/SFD/CRC/pad/FCS/IFG) with 4-bit MII nibble output.
//
// The framer does not start a frame until that whole frame has been committed
// to the FIFO (tracked by a gray-coded committed-frame counter), so it can
// never underrun. Consequently the AXIS input MAY bubble (deassert tvalid
// mid-frame) with no wire underrun and no transmit error - the framer replaces
// the cut-through eth_mac_tx on the MII path.
//
// Overflow policy: backpressure (tready = !full) for well-formed frames; size
// the FIFO >= MAX_FRAME so a valid frame always fits. A runaway frame whose
// no-tlast run reaches MAX_FRAME is force-terminated (synthetic EOF) and its
// tail dropped, so uncommitted data can never fill the FIFO and deadlock the
// framer (see the oversized-frame guard on the write side).
// Verilog 2001
// =============================================================================

module mii_tx_saf #(
    parameter MAX_FRAME       = 1518,   // max raw AXIS payload (dst+src+type+data)
    parameter FIFO_ADDR_WIDTH = 12      // 4096 bytes; must be >= MAX_FRAME
)(
    input  wire        clk,             // sys clock (AXIS write side)
    input  wire        rst_n,

    // ---- AXIS frame input (raw frame: dst+src+type+payload; no preamble/FCS)
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // Gate frame START (sys clk). Low pauses starting new frames (e.g. on an
    // inbound 802.3x PAUSE); an in-flight frame always completes. Tie high if
    // unused.
    input  wire        tx_start_ok,

    // ---- MII output (media clock) ----
    input  wire        mii_tx_clk,
    output wire [3:0]  mii_txd,
    output wire        mii_tx_en,

    // ---- Status (sys clk) ----
    output wire        tx_busy,         // < one frame of FIFO space left
    output wire [12:0] tx_fifo_level,   // FIFO occupancy (write-side count)

    // ---- TX observability for stats/IRQ (sys clk) ----
    output wire        tx_active,       // high while a frame is on the wire
    output wire        tx_byte_stb,     // 1-cycle pulse per byte put on the wire
    output wire        tx_frame_done,   // 1-cycle pulse when a frame finishes

    // ---- Debug (sys clk): read-side framer state synchronized into the write
    //      domain so a CSR/ELA on sys clk sees stable values. Layout:
    //      [5:0] committed frames  [11:6] drained frames (synced)
    //      [12] rd_empty (synced)  [15:13] framer state (synced)
    output wire [15:0] dbg_saf
);

    localparam PREAMBLE_LEN = 7;
    localparam MIN_FRAME    = 60;   // data+pad bytes before the 4-byte FCS
    localparam IFG_BYTES    = 12;

    // Committed-frame counter width. The framer only starts a frame while
    // frame_pending (frame_wr != frame_rd) is set, so this counter must never
    // wrap to a false "equal" before the FIFO backpressures. A 1-byte frame is
    // one FIFO entry, so up to FIFO_DEPTH (=2**FIFO_ADDR_WIDTH) frames can be
    // buffered at once; one extra bit guarantees the difference never aliases.
    localparam FRAME_CNT_W = FIFO_ADDR_WIDTH + 1;

    // =========================================================================
    // mii_tx_clk reset synchronizer
    // =========================================================================
    reg tx_rst_n_s1, tx_rst_n_s2;
    always @(posedge mii_tx_clk or negedge rst_n) begin
        if (!rst_n) {tx_rst_n_s2, tx_rst_n_s1} <= 2'b00;
        else        {tx_rst_n_s2, tx_rst_n_s1} <= {tx_rst_n_s1, 1'b1};
    end

    // =========================================================================
    // AXIS write side (sys clk): {tlast, data} straight into the frame FIFO.
    // tlast is already aligned to the last byte, so no delay stage is needed.
    //
    // Oversized-frame guard. The framer only starts a frame once it is COMMITTED
    // (a tlast byte written, tracked by frame_wr_bin). A contiguous run of bytes
    // with no tlast that reaches the FIFO depth - an oversized frame, or several
    // frames merged by a dropped tlast upstream - would otherwise fill the FIFO
    // with uncommitted data: frame_pending never rises, the framer never starts,
    // wr_full sticks, and the WHOLE TX path deadlocks permanently. To stay robust
    // we cap the in-flight (uncommitted) run at MAX_FRAME: on the MAX_FRAME-th
    // byte with no real tlast we force a synthetic EOF (commit a truncated frame)
    // and then drop the rest of the runaway frame until its real tlast. Because
    // MAX_FRAME < FIFO depth, that forced commit always finds room, so
    // uncommitted data can never fill the FIFO and the framer can always make
    // progress. Well-formed frames (<= MAX_FRAME ending in a real tlast) hit the
    // real tlast first and are never truncated.
    // =========================================================================
    localparam [13:0] OVERSIZE_LIMIT = MAX_FRAME[13:0]; // max bytes written per frame

    wire                     wr_full;
    reg                      dropping;      // discarding the tail of an oversized frame
    reg  [13:0]              frame_bytes;   // bytes written in the current frame so far
    wire                     reached_limit = (frame_bytes == OVERSIZE_LIMIT - 14'd1);
    wire                     eff_last      = s_axis_tlast || reached_limit;
    wire                     forced_cut    = reached_limit && !s_axis_tlast;

    wire                     wr_accept = s_axis_tvalid && !wr_full && !dropping;
    wire                     eof_wr    = wr_accept && eff_last;   // frame committed
    wire [8:0]               wr_data   = {eff_last, s_axis_tdata};
    wire [FIFO_ADDR_WIDTH:0] fifo_count;

    // While dropping a runaway frame's tail, absorb source bytes fast (ready high,
    // no writes) until its real tlast; otherwise ready = !full (backpressure).
    assign s_axis_tready = dropping ? 1'b1 : !wr_full;

    // In-flight byte count + runaway-tail drop state.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dropping    <= 1'b0;
            frame_bytes <= 14'd0;
        end else if (dropping) begin
            if (s_axis_tvalid && s_axis_tlast)   // real end of the dropped frame
                dropping <= 1'b0;
        end else if (wr_accept) begin
            if (eff_last) begin
                frame_bytes <= 14'd0;
                if (forced_cut) dropping <= 1'b1; // truncated: drop the runaway tail
            end else begin
                frame_bytes <= frame_bytes + 14'd1;
            end
        end
    end

    // Committed-frame counter (sys clk): +1 when a frame's (real or forced) last
    // byte is accepted, i.e. a whole frame is now buffered. Gray-coded for the
    // media CDC.
    reg [FRAME_CNT_W-1:0] frame_wr_bin;
    reg [FRAME_CNT_W-1:0] frame_wr_gray;
    wire [FRAME_CNT_W-1:0] frame_wr_next = frame_wr_bin + 1'b1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_wr_bin  <= {FRAME_CNT_W{1'b0}};
            frame_wr_gray <= {FRAME_CNT_W{1'b0}};
        end else if (eof_wr) begin
            frame_wr_bin  <= frame_wr_next;
            frame_wr_gray <= frame_wr_next ^ (frame_wr_next >> 1);
        end
    end

    // "< one frame of space left" busy hint (matches the old tx_start_ok gate).
    localparam [FIFO_ADDR_WIDTH:0] FIFO_DEPTH = {1'b1, {FIFO_ADDR_WIDTH{1'b0}}};

    // Elaboration guard: the oversize cap and the busy_thresh below both rely on
    // MAX_FRAME < FIFO_DEPTH. If misconfigured (e.g. FIFO_ADDR_WIDTH too small),
    // the forced-EOF commit could never find room - reintroducing the permanent
    // TX wedge - and busy_thresh would underflow. Fail synthesis/sim loudly.
    initial begin
        if (MAX_FRAME >= (1 << FIFO_ADDR_WIDTH)) begin
            $display("FATAL: mii_tx_saf requires MAX_FRAME (%0d) < FIFO_DEPTH (%0d)",
                     MAX_FRAME, (1 << FIFO_ADDR_WIDTH));
            $finish;
        end
    end

    wire [FIFO_ADDR_WIDTH:0] busy_thresh = FIFO_DEPTH - MAX_FRAME[FIFO_ADDR_WIDTH:0];
    assign tx_busy       = (fifo_count > busy_thresh);
    // tx_fifo_level is a fixed 13-bit telemetry field, but fifo_count is
    // FIFO_ADDR_WIDTH+1 bits and straddles that width: MAX_FRAME=1518 gives 12
    // bits, the 9018 default gives 15. Padding 13 zeros on top keeps both
    // part-selects in range for any FIFO_ADDR_WIDTH and avoids an implicit
    // width conversion. Saturate rather than truncate, as gmii_cdc does: a
    // truncated occupancy of 8192 would be reported as 0.
    wire [FIFO_ADDR_WIDTH+13:0] fifo_count_pad = {13'b0, fifo_count};
    assign tx_fifo_level = (|fifo_count_pad[FIFO_ADDR_WIDTH+13:13])
                           ? 13'h1FFF : fifo_count_pad[12:0];

    wire [8:0] rd_data;
    wire       rd_empty;
    reg        rd_en;

    async_fifo #(.DATA_WIDTH(9), .ADDR_WIDTH(FIFO_ADDR_WIDTH)) u_fifo (
        .wr_clk       (clk),
        .wr_rst_n     (rst_n),
        .wr_data      (wr_data),
        .wr_en        (wr_accept),
        .wr_full      (wr_full),
        .rd_clk       (mii_tx_clk),
        .rd_rst_n     (tx_rst_n_s2),
        .rd_data      (rd_data),
        .rd_en        (rd_en),
        .rd_empty     (rd_empty),
        .wr_data_count(fifo_count)
    );

    function [FRAME_CNT_W-1:0] gray_to_bin;
        input [FRAME_CNT_W-1:0] gray;
        integer i;
        begin
            gray_to_bin[FRAME_CNT_W-1] = gray[FRAME_CNT_W-1];
            for (i = FRAME_CNT_W-2; i >= 0; i = i - 1)
                gray_to_bin[i] = gray_to_bin[i+1] ^ gray[i];
        end
    endfunction

    // Committed-frame counter CDC into the media domain.
    (* ASYNC_REG = "TRUE" *) reg [FRAME_CNT_W-1:0] frame_wr_s1;
    (* ASYNC_REG = "TRUE" *) reg [FRAME_CNT_W-1:0] frame_wr_s2;
    (* ASYNC_REG = "TRUE" *) reg [FRAME_CNT_W-1:0] frame_wr_s3;
    (* ASYNC_REG = "TRUE" *) reg                   start_ok_s1, start_ok_s2;
    reg [FRAME_CNT_W-1:0] frame_rd_bin;
    always @(posedge mii_tx_clk or negedge tx_rst_n_s2) begin
        if (!tx_rst_n_s2) begin
            frame_wr_s1 <= {FRAME_CNT_W{1'b0}};
            frame_wr_s2 <= {FRAME_CNT_W{1'b0}};
            frame_wr_s3 <= {FRAME_CNT_W{1'b0}};
            start_ok_s1 <= 1'b0;
            start_ok_s2 <= 1'b0;
        end else begin
            frame_wr_s1 <= frame_wr_gray;
            frame_wr_s2 <= frame_wr_s1;
            frame_wr_s3 <= frame_wr_s2;
            start_ok_s1 <= tx_start_ok;
            start_ok_s2 <= start_ok_s1;
        end
    end
    wire [FRAME_CNT_W-1:0] frame_wr_media = gray_to_bin(frame_wr_s3);
    wire                   frame_pending  = (frame_wr_media != frame_rd_bin);

    // =========================================================================
    // CRC-32 (Ethernet FCS), one byte per step - same polynomial as eth_mac_tx.
    // =========================================================================
    function [31:0] crc_step_byte;
        input [31:0] crc_in;
        input [7:0]  data;
        integer i;
        reg [31:0] c;
        begin
            c = crc_in ^ {24'd0, data};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0]) c = {1'b0, c[31:1]} ^ 32'hEDB88320;
                else      c = {1'b0, c[31:1]};
            end
            crc_step_byte = c;
        end
    endfunction

    // =========================================================================
    // Framer FSM (mii_tx_clk). Each byte is emitted low-nibble then high-nibble
    // (nib = 0, 1). Byte advance / next-state decisions happen at nib==1.
    // =========================================================================
    localparam [2:0]
        S_IDLE = 3'd0,
        S_PRE  = 3'd1,
        S_SFD  = 3'd2,
        S_DATA = 3'd3,
        S_PAD  = 3'd4,
        S_FCS  = 3'd5,
        S_IFG  = 3'd6;

    reg [2:0]  st;
    reg        nib;          // 0 = low nibble cycle, 1 = high nibble cycle
    reg [7:0]  cur;          // byte currently being nibbled out
    reg [3:0]  cnt;          // preamble / FCS / IFG byte counter
    reg [13:0] dcnt;         // data + pad byte count
    reg [31:0] crc;
    reg [31:0] crc_saved;
    reg        cur_last;     // tlast of the data byte currently in 'cur'

    reg [3:0]  mii_txd_int;
    reg        mii_tx_en_int;

    // wire the next FCS word combinationally for readability
    wire [31:0] crc_final = ~crc_step_byte(crc, cur);   // for last data/pad byte
    wire [31:0] crc_pad0  = ~crc_step_byte(crc, 8'h00); // for last pad byte

    // Per-byte "on the wire" strobe + frame-done, toggled in media domain and
    // synchronized to sys clk below.
    reg tx_byte_tgl;
    reg tx_done_tgl;
    reg tx_active_media;

    always @(posedge mii_tx_clk) begin
        if (!tx_rst_n_s2) begin
            st            <= S_IDLE;
            nib           <= 1'b0;
            cur           <= 8'd0;
            cnt           <= 4'd0;
            dcnt          <= 14'd0;
            crc           <= 32'hFFFFFFFF;
            crc_saved     <= 32'd0;
            cur_last      <= 1'b0;
            frame_rd_bin  <= {FRAME_CNT_W{1'b0}};
            rd_en         <= 1'b0;
            mii_txd_int   <= 4'd0;
            mii_tx_en_int <= 1'b0;
            tx_byte_tgl   <= 1'b0;
            tx_done_tgl   <= 1'b0;
            tx_active_media <= 1'b0;
        end else begin
            rd_en <= 1'b0;

            case (st)
                S_IDLE: begin
                    mii_tx_en_int <= 1'b0;
                    nib           <= 1'b0;
                    tx_active_media <= 1'b0;
                    if (frame_pending && !rd_empty && start_ok_s2) begin
                        // tx_en is raised in the first S_PRE cycle (default
                        // branch) together with the first nibble, so it stays
                        // aligned with mii_txd. Raising it here would emit one
                        // stale nibble while tx_en is already high.
                        st              <= S_PRE;
                        cur             <= 8'h55;
                        cnt             <= 4'd0;
                        nib             <= 1'b0;
                        tx_active_media <= 1'b1;
                    end
                end

                default: begin
                    // Drive the nibble every cycle of a data-bearing state.
                    mii_txd_int   <= nib ? cur[7:4] : cur[3:0];
                    mii_tx_en_int <= (st != S_IFG);

                    if (!nib) begin
                        nib <= 1'b1;
                    end else begin
                        nib <= 1'b0;
                        if (st != S_IFG)
                            tx_byte_tgl <= ~tx_byte_tgl;   // one wire byte emitted

                        case (st)
                            S_PRE: begin
                                if (cnt == PREAMBLE_LEN - 1) begin
                                    st  <= S_SFD;
                                    cur <= 8'hD5;
                                end else begin
                                    cnt <= cnt + 4'd1;
                                    cur <= 8'h55;
                                end
                            end

                            S_SFD: begin
                                // Load the first payload byte (FWFT: rd_data is
                                // already the frame's byte 0) and consume it.
                                st       <= S_DATA;
                                cur      <= rd_data[7:0];
                                cur_last <= rd_data[8];
                                rd_en    <= 1'b1;
                                dcnt     <= 14'd0;
                                crc      <= 32'hFFFFFFFF;
                            end

                            S_DATA: begin
                                crc  <= crc_step_byte(crc, cur);
                                dcnt <= dcnt + 14'd1;
                                if (cur_last) begin
                                    if (dcnt + 14'd1 < MIN_FRAME) begin
                                        st  <= S_PAD;
                                        cur <= 8'h00;
                                    end else begin
                                        crc_saved <= crc_final;
                                        cur       <= crc_final[7:0];
                                        st        <= S_FCS;
                                        cnt       <= 4'd0;
                                    end
                                end else begin
                                    cur      <= rd_data[7:0];
                                    cur_last <= rd_data[8];
                                    rd_en    <= 1'b1;
                                end
                            end

                            S_PAD: begin
                                crc  <= crc_step_byte(crc, 8'h00);
                                dcnt <= dcnt + 14'd1;
                                if (dcnt + 14'd1 >= MIN_FRAME) begin
                                    crc_saved <= crc_pad0;
                                    cur       <= crc_pad0[7:0];
                                    st        <= S_FCS;
                                    cnt       <= 4'd0;
                                end else begin
                                    cur <= 8'h00;
                                end
                            end

                            S_FCS: begin
                                case (cnt)
                                    4'd0: cur <= crc_saved[15:8];
                                    4'd1: cur <= crc_saved[23:16];
                                    4'd2: cur <= crc_saved[31:24];
                                    default: cur <= 8'd0;
                                endcase
                                if (cnt == 4'd3) begin
                                    st  <= S_IFG;
                                    cnt <= 4'd0;
                                end else begin
                                    cnt <= cnt + 4'd1;
                                end
                            end

                            S_IFG: begin
                                if (cnt == IFG_BYTES - 1) begin
                                    st           <= S_IDLE;
                                    frame_rd_bin <= frame_rd_bin + 1'b1;
                                    tx_done_tgl  <= ~tx_done_tgl;
                                end else begin
                                    cnt <= cnt + 4'd1;
                                end
                            end

                            default: st <= S_IDLE;
                        endcase
                    end
                end
            endcase
        end
    end

    // Dedicated IOB output registers (fanout=1, drive pad only).
    (* IOB = "TRUE" *) reg [3:0] mii_txd_iob;
    (* IOB = "TRUE" *) reg       mii_tx_en_iob;
    always @(posedge mii_tx_clk) begin
        if (!tx_rst_n_s2) begin
            mii_txd_iob   <= 4'd0;
            mii_tx_en_iob <= 1'b0;
        end else begin
            mii_txd_iob   <= mii_txd_int;
            mii_tx_en_iob <= mii_tx_en_int;
        end
    end
    assign mii_txd   = mii_txd_iob;
    assign mii_tx_en = mii_tx_en_iob;

    // =========================================================================
    // TX observability CDC (media -> sys). At MII byte rate (<= 12.5 MB/s) a
    // toggle-per-event resolves cleanly against the 100 MHz sys clk.
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg tx_byte_s1, tx_byte_s2, tx_byte_s3;
    (* ASYNC_REG = "TRUE" *) reg tx_done_s1, tx_done_s2, tx_done_s3;
    (* ASYNC_REG = "TRUE" *) reg tx_active_s1, tx_active_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_byte_s1 <= 1'b0; tx_byte_s2 <= 1'b0; tx_byte_s3 <= 1'b0;
            tx_done_s1 <= 1'b0; tx_done_s2 <= 1'b0; tx_done_s3 <= 1'b0;
            tx_active_s1 <= 1'b0; tx_active_s2 <= 1'b0;
        end else begin
            tx_byte_s1 <= tx_byte_tgl; tx_byte_s2 <= tx_byte_s1; tx_byte_s3 <= tx_byte_s2;
            tx_done_s1 <= tx_done_tgl; tx_done_s2 <= tx_done_s1; tx_done_s3 <= tx_done_s2;
            tx_active_s1 <= tx_active_media; tx_active_s2 <= tx_active_s1;
        end
    end
    assign tx_byte_stb   = tx_byte_s2 ^ tx_byte_s3;
    assign tx_frame_done = tx_done_s2 ^ tx_done_s3;
    assign tx_active     = tx_active_s2;

    // =========================================================================
    // Debug: synchronize the read-side (mii_tx_clk) framer signals into the
    // write (sys) domain. Plain 2-FF sync - values are only read while the
    // framer is quiescent/stuck, so multi-bit skew is not a concern here.
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [FRAME_CNT_W-1:0] frame_rd_ws1, frame_rd_ws2;
    (* ASYNC_REG = "TRUE" *) reg                   rd_empty_ws1, rd_empty_ws2;
    (* ASYNC_REG = "TRUE" *) reg [2:0]             st_ws1, st_ws2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_rd_ws1 <= {FRAME_CNT_W{1'b0}}; frame_rd_ws2 <= {FRAME_CNT_W{1'b0}};
            rd_empty_ws1 <= 1'b1;                rd_empty_ws2 <= 1'b1;
            st_ws1       <= 3'd0;                st_ws2       <= 3'd0;
        end else begin
            frame_rd_ws1 <= frame_rd_bin; frame_rd_ws2 <= frame_rd_ws1;
            rd_empty_ws1 <= rd_empty;     rd_empty_ws2 <= rd_empty_ws1;
            st_ws1       <= st;           st_ws2       <= st_ws1;
        end
    end
    assign dbg_saf = {st_ws2, rd_empty_ws2, frame_rd_ws2[5:0], frame_wr_bin[5:0]};

endmodule
