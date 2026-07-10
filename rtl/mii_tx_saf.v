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
// Overflow policy: backpressure (tready = !full). Size the FIFO >= MAX_FRAME so
// a valid frame always fits; a runaway (never-tlast) frame would stall the
// source, which is the intended flow-control behaviour.
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
    output wire        tx_frame_done    // 1-cycle pulse when a frame finishes
);

    localparam PREAMBLE_LEN = 7;
    localparam MIN_FRAME    = 60;   // data+pad bytes before the 4-byte FCS
    localparam IFG_BYTES    = 12;

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
    // =========================================================================
    wire [8:0]               wr_data   = {s_axis_tlast, s_axis_tdata};
    wire                     wr_full;
    wire                     wr_accept = s_axis_tvalid && !wr_full;
    wire                     eof_wr    = wr_accept && s_axis_tlast;
    wire [FIFO_ADDR_WIDTH:0] fifo_count;

    assign s_axis_tready = !wr_full;

    // Committed-frame counter (sys clk): +1 when a frame's tlast byte is
    // accepted, i.e. a whole frame is now buffered. Gray-coded for the media CDC.
    reg [3:0] frame_wr_bin;
    reg [3:0] frame_wr_gray;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_wr_bin  <= 4'd0;
            frame_wr_gray <= 4'd0;
        end else if (eof_wr) begin
            frame_wr_bin  <= frame_wr_bin + 4'd1;
            frame_wr_gray <= (frame_wr_bin + 4'd1) ^ ((frame_wr_bin + 4'd1) >> 1);
        end
    end

    // "< one frame of space left" busy hint (matches the old tx_start_ok gate).
    localparam [FIFO_ADDR_WIDTH:0] FIFO_DEPTH = {1'b1, {FIFO_ADDR_WIDTH{1'b0}}};
    wire [FIFO_ADDR_WIDTH:0] busy_thresh = FIFO_DEPTH - MAX_FRAME[FIFO_ADDR_WIDTH:0];
    assign tx_busy       = (fifo_count > busy_thresh);
    assign tx_fifo_level = fifo_count[12:0];

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

    function [3:0] gray4_to_bin;
        input [3:0] gray;
        begin
            gray4_to_bin[3] = gray[3];
            gray4_to_bin[2] = gray4_to_bin[3] ^ gray[2];
            gray4_to_bin[1] = gray4_to_bin[2] ^ gray[1];
            gray4_to_bin[0] = gray4_to_bin[1] ^ gray[0];
        end
    endfunction

    // Committed-frame counter CDC into the media domain.
    (* ASYNC_REG = "TRUE" *) reg [3:0] frame_wr_s1;
    (* ASYNC_REG = "TRUE" *) reg [3:0] frame_wr_s2;
    (* ASYNC_REG = "TRUE" *) reg [3:0] frame_wr_s3;
    reg [3:0] frame_rd_bin;
    always @(posedge mii_tx_clk or negedge tx_rst_n_s2) begin
        if (!tx_rst_n_s2) begin
            frame_wr_s1 <= 4'd0;
            frame_wr_s2 <= 4'd0;
            frame_wr_s3 <= 4'd0;
        end else begin
            frame_wr_s1 <= frame_wr_gray;
            frame_wr_s2 <= frame_wr_s1;
            frame_wr_s3 <= frame_wr_s2;
        end
    end
    wire [3:0] frame_wr_media = gray4_to_bin(frame_wr_s3);
    wire       frame_pending  = (frame_wr_media != frame_rd_bin);

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
            frame_rd_bin  <= 4'd0;
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
                    if (frame_pending && !rd_empty) begin
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
                                    frame_rd_bin <= frame_rd_bin + 4'd1;
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

endmodule
