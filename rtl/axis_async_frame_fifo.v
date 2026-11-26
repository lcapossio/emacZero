// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// axis_async_frame_fifo.v - asynchronous store-and-forward frame FIFO
//
// Frames go in on wr_clk and come out on rd_clk, whole: the read side sees a
// frame only once its last word has been written, so a frame is never read
// out faster than it arrives and never cut short. A frame can be dropped as
// it is written:
//   - s_drop on any of its words (the 10G RX path uses it for the address
//     filter and for bad frames): the write pointer goes back to the start of
//     the frame and nothing of it is ever read.
//   - no room: with DROP_WHEN_FULL=1 (a writer with no backpressure, such as
//     the RX MAC) a word that finds the FIFO full drops its frame, and the
//     rest of that frame is discarded. With DROP_WHEN_FULL=0, s_ready
//     backpressures the writer instead, and a frame is dropped only when it
//     alone fills the whole FIFO (it could never complete).
// One pulse per frame reports what happened: wr_frame_ok, wr_frame_drop
// (s_drop) or wr_frame_overflow (no room).
//
// Clock crossing: the read pointer crosses to the write side in Gray code as
// usual. The committed write pointer jumps by a whole frame at once, so it
// crosses by handshake instead: the write side holds a snapshot of it and
// toggles a request; the read side, once the request is through its
// synchronizer, takes the (by then stable) snapshot and toggles an
// acknowledge back; then the next snapshot can go. The read side therefore
// only ever learns of whole frames, and can read a frame as fast as it likes,
// whichever clock is faster. One transfer takes about three cycles of each
// clock and carries every frame committed since the last one.
//
// Reset: both sides hold pointers into the same memory, so reset them
// together. With one side reset alone, the other would go on from its old
// pointer and read or overwrite stale memory. Both must be in reset at once
// at some point; either may come out first (eth_mac_sys_10g resets each
// crossing whole).
//
// Storage is block RAM with a registered read into a one-word output stage
// (the first-word-fall-through head), one word per rd_clk sustained.
// m_data / m_last are valid while m_valid is high; m_valid && m_ready pops.
// Verilog 2001
// =============================================================================

module axis_async_frame_fifo #(
    parameter DATA_WIDTH     = 73,
    parameter ADDR_WIDTH     = 11,      // depth 2**ADDR_WIDTH words
    parameter DROP_WHEN_FULL = 1
) (
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire [DATA_WIDTH-1:0] s_data,
    input  wire                  s_last,
    input  wire                  s_drop,
    input  wire                  s_valid,
    output wire                  s_ready,
    output reg                   wr_frame_ok,
    output reg                   wr_frame_drop,
    output reg                   wr_frame_overflow,
    // words held, write side: lags reads by the pointer sync, never under
    output wire [ADDR_WIDTH:0]   wr_count,

    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    output wire [DATA_WIDTH-1:0] m_data,
    output wire                  m_last,
    output wire                  m_valid,
    input  wire                  m_ready
);

    localparam DEPTH = 1 << ADDR_WIDTH;
    localparam W     = ADDR_WIDTH + 1;

    function [W-1:0] bin2gray;
        input [W-1:0] b;
        begin
            bin2gray = b ^ (b >> 1);
        end
    endfunction

    function [W-1:0] gray2bin;
        input [W-1:0] g;
        integer       i;
        reg   [W-1:0] b;
        begin
            b = g;
            for (i = 1; i < W; i = i + 1)
                b = b ^ (g >> i);
            gray2bin = b;
        end
    endfunction

    (* ram_style = "block" *) reg [DATA_WIDTH:0] mem [0:DEPTH-1];
    reg  [W-1:0] rd_ptr;            // read side: next word to read
    reg  [W-1:0] rd_gray;
    reg          ack;               // read side: acknowledge toggle

    // ------------------------------------------------------------ write side
    reg  [W-1:0] wr_ptr;            // next word to write
    reg  [W-1:0] commit;            // end of the last whole frame
    reg  [W-1:0] snap;              // commit as last offered to the read side
    reg          req;               // toggles to offer snap
    (* ASYNC_REG = "TRUE" *) reg ack_s1;
    (* ASYNC_REG = "TRUE" *) reg ack_s2;
    reg          discard;           // dropping the rest of a frame
    reg          drop_acc;          // s_drop seen earlier in this frame
    (* ASYNC_REG = "TRUE" *) reg [W-1:0] rd_gray_s1;  // read pointer, synchronized
    (* ASYNC_REG = "TRUE" *) reg [W-1:0] rd_gray_s2;

    wire [W-1:0] rd_bin_w = gray2bin(rd_gray_s2);
    wire [W-1:0] used     = wr_ptr - rd_bin_w;
    wire         full     = used[ADDR_WIDTH];
    // a frame that alone fills the FIFO can never complete
    wire [W-1:0] fsize    = wr_ptr - commit;
    wire         stuck    = full && fsize[ADDR_WIDTH];

    assign s_ready  = (DROP_WHEN_FULL != 0) ? 1'b1 : (discard || !full);
    assign wr_count = used;

    wire beat = s_valid && s_ready;

    always @(posedge wr_clk) begin
        if (beat && !discard && !full)
            mem[wr_ptr[ADDR_WIDTH-1:0]] <= {s_last, s_data};
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr   <= {W{1'b0}};
            commit   <= {W{1'b0}};
            snap     <= {W{1'b0}};
            req      <= 1'b0;
            discard  <= 1'b0;
            drop_acc <= 1'b0;
            wr_frame_ok       <= 1'b0;
            wr_frame_drop     <= 1'b0;
            wr_frame_overflow <= 1'b0;
        end else begin
            wr_frame_ok       <= 1'b0;
            wr_frame_drop     <= 1'b0;
            wr_frame_overflow <= 1'b0;

            // offer the latest commit once the last offer is acknowledged
            if (req == ack_s2 && snap != commit) begin
                snap <= commit;
                req  <= !req;
            end

            if (beat) begin
                if (discard) begin
                    if (s_last) begin
                        discard           <= 1'b0;
                        wr_frame_overflow <= 1'b1;
                    end
                end else if (full) begin
                    // only reachable with DROP_WHEN_FULL=1: no room
                    wr_ptr   <= commit;
                    drop_acc <= 1'b0;
                    if (s_last)
                        wr_frame_overflow <= 1'b1;
                    else
                        discard <= 1'b1;
                end else if (s_last) begin
                    drop_acc <= 1'b0;
                    if (drop_acc || s_drop) begin
                        wr_ptr        <= commit;
                        wr_frame_drop <= 1'b1;
                    end else begin
                        wr_ptr      <= wr_ptr + 1'b1;
                        commit      <= wr_ptr + 1'b1;
                        wr_frame_ok <= 1'b1;
                    end
                end else begin
                    wr_ptr   <= wr_ptr + 1'b1;
                    drop_acc <= drop_acc || s_drop;
                end
            end else if (stuck && !discard && (DROP_WHEN_FULL == 0)) begin
                // backpressure mode: the frame being written fills the FIFO
                wr_ptr   <= commit;
                drop_acc <= 1'b0;
                discard  <= 1'b1;
            end
        end
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_gray_s1 <= {W{1'b0}};
            rd_gray_s2 <= {W{1'b0}};
            ack_s1     <= 1'b0;
            ack_s2     <= 1'b0;
        end else begin
            rd_gray_s1 <= rd_gray;
            rd_gray_s2 <= rd_gray_s1;
            ack_s1     <= ack;
            ack_s2     <= ack_s1;
        end
    end

    // ------------------------------------------------------------- read side
    (* ASYNC_REG = "TRUE" *) reg req_s1;
    (* ASYNC_REG = "TRUE" *) reg req_s2;
    reg  [W-1:0] avail;             // end of the frames the read side knows of

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            req_s1 <= 1'b0;
            req_s2 <= 1'b0;
            ack    <= 1'b0;
            avail  <= {W{1'b0}};
        end else begin
            req_s1 <= req;
            req_s2 <= req_s1;
            if (req_s2 != ack) begin
                avail <= snap;      // held since req toggled
                ack   <= req_s2;
            end
        end
    end

    wire mem_empty = (rd_ptr == avail);

    reg  [DATA_WIDTH:0] head;       // block RAM read register, no reset
    reg                 head_v;
    wire                pop    = m_ready && head_v;
    wire                mem_rd = !mem_empty && (!head_v || pop);

    always @(posedge rd_clk) begin
        if (mem_rd)
            head <= mem[rd_ptr[ADDR_WIDTH-1:0]];
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr  <= {W{1'b0}};
            rd_gray <= {W{1'b0}};
            head_v  <= 1'b0;
        end else begin
            if (mem_rd) begin
                rd_ptr  <= rd_ptr + 1'b1;
                rd_gray <= bin2gray(rd_ptr + 1'b1);
                head_v  <= 1'b1;
            end else if (pop) begin
                head_v  <= 1'b0;
            end
        end
    end

    assign m_valid = head_v;
    assign m_data  = head[DATA_WIDTH-1:0];
    assign m_last  = head[DATA_WIDTH];

endmodule
