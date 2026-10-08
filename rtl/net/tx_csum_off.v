// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tx_csum_off.v - TX checksum offload: IPv4 header, TCP, UDP, ICMP, ICMPv6
// Verilog 2001
// =============================================================================
// Inline AXI4-Stream stage between the network stack and the MAC TX. For each
// frame with `enable` high (sampled at the frame's first byte) it computes and
// writes:
//   - the IPv4 header checksum (any IHL), and
//   - the TCP / UDP / ICMP checksum over IPv4, or the TCP / UDP / ICMPv6
//     checksum over IPv6 (pseudo-header included where the protocol uses it),
// with an optional single 802.1Q / 802.1ad tag. Whatever software left in
// those fields is ignored. A UDP checksum that computes to 0 is sent as
// 0xFFFF. Scope and limits are those of csum_calc.v: IPv4 fragments and IPv6
// packets with extension headers get no L4 checksum (the IPv4 header checksum
// is still written), and other frames pass unchanged. With `enable` low a
// frame passes unchanged.
//
// The checksum fields precede the bytes they cover, so the stage stores each
// frame before sending it: a circular byte buffer (sync_fifo) holds frames,
// and a small metadata FIFO holds each committed frame's patch values and
// positions. The next frame is taken in while the previous one drains, so a
// buffer one MAX_FRAME deep sustains 1 byte/clk; the per-frame cost is a
// 5-cycle pause in s_axis_tready after each TLAST while the sums settle.
//
// A frame longer than MAX_FRAME bytes is cut at MAX_FRAME (TLAST forced on the
// last kept byte, the rest discarded up to the real TLAST) and sent unpatched,
// so an oversized or unterminated frame can never fill the buffer and
// deadlock. BUF_ADDR_WIDTH must give a buffer deeper than MAX_FRAME.
// =============================================================================

module tx_csum_off #(
    parameter MAX_FRAME       = 9018,
    // Byte buffer depth 2^BUF_ADDR_WIDTH; must exceed MAX_FRAME. One
    // MAX_FRAME is enough for full rate (one frame drains while the next fills).
    parameter BUF_ADDR_WIDTH  = $clog2(MAX_FRAME + 8),
    parameter META_ADDR_WIDTH = 4      // committed frames held: 2^N
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    // Ingress (from network stack)
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // Egress (to MAC TX)
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast
);

    localparam META_DEPTH = 1 << META_ADDR_WIDTH;
    // csum_calc results are final 3 cycles after the last byte; commit on the
    // 4th.
    localparam [2:0] FLUSH_CYC = 3'd4;

    // =========================================================================
    // Ingest
    // =========================================================================
    localparam [1:0] IN_DATA  = 2'd0,   // accepting frame bytes
                     IN_FLUSH = 2'd1,   // frame stored; sums settling, then commit
                     IN_DROP  = 2'd2;   // discarding a cut frame's tail

    reg  [1:0]  in_state;
    reg  [13:0] in_cnt;        // bytes of the current frame accepted so far
    reg         en_frame;      // `enable` latched at the frame's first byte
    reg         cut;           // frame was cut at MAX_FRAME
    reg  [2:0]  flush_cnt;

    wire        buf_full;
    wire        meta_full;

    assign s_axis_tready = (in_state == IN_DATA && !buf_full) ||
                           (in_state == IN_DROP);

    wire in_hs   = s_axis_tvalid && s_axis_tready && (in_state == IN_DATA);
    wire at_max  = (in_cnt == MAX_FRAME - 1);
    wire in_last = s_axis_tlast || at_max;     // TLAST as written to the buffer

    // Checksum engine on the accepted bytes
    wire        c_done, c_ip4, c_l4_ok, c_l4_udp;
    wire [13:0] c_l3_end, c_ip_pos, c_l4_pos;
    wire [15:0] c_ip_sum, c_l4_sum, c_l4_field;

    csum_calc u_calc (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_valid    (in_hs),
        .in_idx      (in_cnt),
        .in_data     (s_axis_tdata),
        .zero_fields (1'b1),
        .done        (c_done),
        .l3_end      (c_l3_end),
        .ip4         (c_ip4),
        .ip_sum      (c_ip_sum),
        .ip_csum_pos (c_ip_pos),
        .l4_ok       (c_l4_ok),
        .l4_udp      (c_l4_udp),
        .l4_sum      (c_l4_sum),
        .l4_csum_pos (c_l4_pos),
        .l4_field    (c_l4_field)
    );

    wire [15:0] ip_csum   = ~c_ip_sum;
    wire [15:0] l4_csum_c = ~c_l4_sum;
    wire [15:0] l4_csum   = (c_l4_udp && l4_csum_c == 16'h0000) ? 16'hFFFF
                                                                : l4_csum_c;
    wire        patch_ok  = en_frame && !cut && c_done;

    // Metadata word: {ip_patch, ip_csum, ip_pos, l4_patch, l4_csum, l4_pos}
    localparam META_W = 1 + 16 + 14 + 1 + 16 + 14;
    wire [META_W-1:0] meta_in = {patch_ok && c_ip4,   ip_csum, c_ip_pos,
                                 patch_ok && c_l4_ok, l4_csum, c_l4_pos};

    wire commit = (in_state == IN_FLUSH) && (flush_cnt == 3'd0) && !meta_full;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_state  <= IN_DATA;
            in_cnt    <= 14'd0;
            en_frame  <= 1'b0;
            cut       <= 1'b0;
            flush_cnt <= 3'd0;
        end else begin
            case (in_state)
                IN_DATA: if (in_hs) begin
                    if (in_cnt == 14'd0)
                        en_frame <= enable;
                    if (in_last) begin
                        in_state  <= IN_FLUSH;
                        flush_cnt <= FLUSH_CYC - 3'd1;
                        cut       <= at_max && !s_axis_tlast;
                    end else begin
                        in_cnt <= in_cnt + 14'd1;
                    end
                end

                IN_FLUSH: begin
                    if (flush_cnt != 3'd0)
                        flush_cnt <= flush_cnt - 3'd1;
                    if (commit) begin
                        in_cnt   <= 14'd0;
                        in_state <= cut ? IN_DROP : IN_DATA;
                        cut      <= 1'b0;
                    end
                end

                IN_DROP: if (s_axis_tvalid && s_axis_tlast)
                    in_state <= IN_DATA;

                default: in_state <= IN_DATA;
            endcase
        end
    end

    // =========================================================================
    // Storage: frame bytes {tlast, data}; per-frame patch metadata
    // =========================================================================
    wire [8:0] buf_rd_data;
    wire       buf_rd_valid;
    wire       buf_pop;

    sync_fifo #(
        .DATA_WIDTH (9),
        .ADDR_WIDTH (BUF_ADDR_WIDTH)
    ) u_buf (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_data     ({in_last, s_axis_tdata}),
        .wr_en       (in_hs),
        .wr_full     (buf_full),
        .rd_data     (buf_rd_data),
        .rd_valid    (buf_rd_valid),
        .rd_en       (buf_pop),
        .rd_empty    (),
        .count       (),
        .wr_overflow ()
    );

    reg  [META_W-1:0]        meta_mem [0:META_DEPTH-1];
    reg  [META_ADDR_WIDTH:0] meta_wr;
    reg  [META_ADDR_WIDTH:0] meta_rd;
    wire                     meta_valid = (meta_wr != meta_rd);
    wire                     meta_pop;

    assign meta_full = ((meta_wr - meta_rd) == META_DEPTH[META_ADDR_WIDTH:0]);

    always @(posedge clk) begin
        if (commit)
            meta_mem[meta_wr[META_ADDR_WIDTH-1:0]] <= meta_in;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta_wr <= {META_ADDR_WIDTH+1{1'b0}};
            meta_rd <= {META_ADDR_WIDTH+1{1'b0}};
        end else begin
            if (commit)   meta_wr <= meta_wr + 1'b1;
            if (meta_pop) meta_rd <= meta_rd + 1'b1;
        end
    end

    // =========================================================================
    // Egress: the head frame's bytes, once its metadata is committed
    // =========================================================================
    wire [META_W-1:0] meta_q = meta_mem[meta_rd[META_ADDR_WIDTH-1:0]];
    wire        q_ip_patch = meta_q[61];
    wire [15:0] q_ip_csum  = meta_q[60:45];
    wire [13:0] q_ip_pos   = meta_q[44:31];
    wire        q_l4_patch = meta_q[30];
    wire [15:0] q_l4_csum  = meta_q[29:14];
    wire [13:0] q_l4_pos   = meta_q[13:0];

    reg  [13:0] eg_pos;        // offset of the head byte within its frame

    assign m_axis_tvalid = buf_rd_valid && meta_valid;
    assign m_axis_tlast  = buf_rd_data[8];
    assign buf_pop       = m_axis_tvalid && m_axis_tready;
    assign meta_pop      = buf_pop && buf_rd_data[8];

    assign m_axis_tdata =
        (q_ip_patch && eg_pos == q_ip_pos)         ? q_ip_csum[15:8] :
        (q_ip_patch && eg_pos == q_ip_pos + 14'd1) ? q_ip_csum[7:0]  :
        (q_l4_patch && eg_pos == q_l4_pos)         ? q_l4_csum[15:8] :
        (q_l4_patch && eg_pos == q_l4_pos + 14'd1) ? q_l4_csum[7:0]  :
                                                     buf_rd_data[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            eg_pos <= 14'd0;
        else if (buf_pop)
            eg_pos <= buf_rd_data[8] ? 14'd0 : eg_pos + 14'd1;
    end

endmodule
