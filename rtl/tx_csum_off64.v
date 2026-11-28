// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tx_csum_off64.v - TX checksum offload for 64-bit streams: IPv4 header, TCP,
// UDP, ICMP, ICMPv6
// Verilog 2001
// =============================================================================
// Inline AXI4-Stream stage ahead of the 10G MAC's TX FIFO (eth_mac_sys_10g,
// TX_CSUM_OFFLOAD=1); the 10G counterpart of rtl/net/tx_csum_off.v. For each
// frame with `enable` high (taken with the frame's first beat) it computes
// and writes the IPv4 header checksum and the TCP / UDP / ICMP / ICMPv6
// checksum, whatever software left in those fields, within csum_calc64's
// scope (outside it the L4 field, or the whole frame, passes unchanged). A
// UDP checksum that computes to 0 is sent as 0xFFFF. As on 1G, the IPv4
// header checksum is written only when the whole datagram is in the frame.
//
// The checksum fields precede the bytes they cover, so the stage stores each
// frame before sending it: a buffer of 2**BUF_ADDR_WIDTH words (sync_fifo)
// holds frames, and a metadata FIFO each stored frame's patch values
// and positions, written csum_calc64's LATENCY cycles after the frame's last
// beat. Frames are taken back to back at one beat per clock; a frame leaves
// once its metadata is in, so the stage adds about a frame plus 8 cycles of
// latency and no gaps.
//
// s_axis: tkeep all ones except on the last beat. tuser on any beat is
// carried to the same beat of m_axis. A frame of more than
// 2**BUF_ADDR_WIDTH words cannot be stored whole: it is cut there (m_axis
// tlast on its last stored word, the rest discarded up to its own tlast) and
// m_drop is high with each of its words, so the frame FIFO behind drops it.
// =============================================================================

module tx_csum_off64 #(
    parameter BUF_ADDR_WIDTH  = 11,     // buffer 2**n words
    // frames stored with their metadata, 2**n: by default as many 8-beat
    // (60-byte) frames as the buffer holds, so a long frame on its way out
    // does not hold off the minimum frames queued behind it
    parameter META_ADDR_WIDTH = BUF_ADDR_WIDTH - 3
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_tuser,
    output wire        m_drop           // this frame is to be dropped (cut)
);

    localparam MAX_BEATS  = 1 << BUF_ADDR_WIDTH;
    localparam META_DEPTH = 1 << META_ADDR_WIDTH;
    localparam CW         = BUF_ADDR_WIDTH + 1;
    localparam MW         = META_ADDR_WIDTH + 1;

    // =========================================================================
    // Ingest
    // =========================================================================
    reg           in_drop;          // discarding a cut frame's tail
    reg           in_mid;           // past a frame's first beat
    reg           en_f;             // enable, taken with the first beat
    reg  [CW-1:0] in_cnt;           // beats of the frame taken so far
    reg  [MW-1:0] inflight;         // frames taken, metadata not yet written
    reg  [MW-1:0] meta_wr, meta_rd;
    wire          buf_full;

    // a frame starts only with room for its metadata
    wire [MW:0] meta_need = {1'b0, meta_wr - meta_rd} + {1'b0, inflight};
    wire        meta_room = (meta_need < META_DEPTH);

    assign s_axis_tready = in_drop || (!buf_full && (in_mid || meta_room));

    wire in_hs   = s_axis_tvalid && s_axis_tready && !in_drop;
    wire at_max  = (in_cnt == MAX_BEATS - 1);
    wire in_last = s_axis_tlast || at_max;
    wire cut_now = at_max && !s_axis_tlast;
    wire en_now  = in_mid ? en_f : enable;

    // checksum engine on the beats taken; tag = {enable, cut}
    wire        c_v, c_done, c_ip4, c_l4_ok, c_l4_udp;
    wire [1:0]  c_tag;
    wire [13:0] c_ip_pos, c_l4_pos;
    wire [15:0] c_ip_sum, c_l4_sum;

    csum_calc64 #(.TAG_W(2)) u_calc (
        .clk          (clk),
        .rst_n        (rst_n),
        .zero_fields  (1'b1),
        .in_valid     (in_hs),
        .in_data      (s_axis_tdata),
        .in_keep      (s_axis_tkeep),
        .in_last      (in_last),
        .in_tag       ({en_now, cut_now}),
        .res_valid    (c_v),
        .res_tag      (c_tag),
        .res_done     (c_done),
        .res_ip4      (c_ip4),
        .res_ip_sum   (c_ip_sum),
        .res_ip_pos   (c_ip_pos),
        .res_l4_ok    (c_l4_ok),
        .res_l4_udp   (c_l4_udp),
        .res_l4_sum   (c_l4_sum),
        .res_l4_pos   (c_l4_pos),
        .res_l4_field ()
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_drop  <= 1'b0;
            in_mid   <= 1'b0;
            en_f     <= 1'b0;
            in_cnt   <= {CW{1'b0}};
            inflight <= {MW{1'b0}};
        end else begin
            if (in_hs) begin
                if (!in_mid)
                    en_f <= enable;
                in_mid <= !in_last;
                in_cnt <= in_last ? {CW{1'b0}} : in_cnt + 1'b1;
                if (cut_now)
                    in_drop <= 1'b1;
            end else if (in_drop && s_axis_tvalid && s_axis_tlast) begin
                in_drop <= 1'b0;
            end
            inflight <= inflight + {{MW-1{1'b0}}, in_hs && in_last}
                                 - {{MW-1{1'b0}}, c_v};
        end
    end

    // =========================================================================
    // Storage: words {tuser, tlast, tkeep, tdata}; per-frame metadata
    // =========================================================================
    wire [73:0] buf_q;
    wire        buf_v;
    wire        buf_pop;

    sync_fifo #(
        .DATA_WIDTH (74),
        .ADDR_WIDTH (BUF_ADDR_WIDTH)
    ) u_buf (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_data     ({s_axis_tuser, in_last, s_axis_tkeep, s_axis_tdata}),
        .wr_en       (in_hs),
        .wr_full     (buf_full),
        .rd_data     (buf_q),
        .rd_valid    (buf_v),
        .rd_en       (buf_pop),
        .rd_empty    (),
        .count       (),
        .wr_overflow ()
    );

    wire [15:0] ip_csum   = ~c_ip_sum;
    wire [15:0] l4_csum_c = ~c_l4_sum;
    wire [15:0] l4_csum   = (c_l4_udp && l4_csum_c == 16'h0000) ? 16'hFFFF
                                                                : l4_csum_c;
    wire        patch_ok  = c_tag[1] && !c_tag[0] && c_done;

    // {drop, ip_patch, ip_csum, ip_pos, l4_patch, l4_csum, l4_pos}
    localparam META_W = 1 + 1 + 16 + 14 + 1 + 16 + 14;
    wire [META_W-1:0] meta_in = {c_tag[0],
                                 patch_ok && c_ip4,   ip_csum, c_ip_pos,
                                 patch_ok && c_l4_ok, l4_csum, c_l4_pos};

    reg  [META_W-1:0] meta_mem [0:META_DEPTH-1];
    wire              meta_v = (meta_wr != meta_rd);
    wire              meta_pop;

    always @(posedge clk) begin
        if (c_v)
            meta_mem[meta_wr[MW-2:0]] <= meta_in;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta_wr <= {MW{1'b0}};
            meta_rd <= {MW{1'b0}};
        end else begin
            if (c_v)      meta_wr <= meta_wr + 1'b1;
            if (meta_pop) meta_rd <= meta_rd + 1'b1;
        end
    end

    // =========================================================================
    // Egress: the head frame's words once its metadata is in, patched
    // =========================================================================
    wire [META_W-1:0] mq = meta_mem[meta_rd[MW-2:0]];
    wire        q_drop     = mq[62];
    wire        q_ip_patch = mq[61];
    wire [15:0] q_ip_csum  = mq[60:45];
    wire [13:0] q_ip_pos   = mq[44:31];
    wire        q_l4_patch = mq[30];
    wire [15:0] q_l4_csum  = mq[29:14];
    wire [13:0] q_l4_pos   = mq[13:0];

    reg  [CW-1:0] eg_b;             // beat index of the head word

    // replace the 16-bit field at even lane 2*w of d with v (MSB first)
    function [63:0] patch16;
        input [63:0] d;
        input [1:0]  w;
        input [15:0] v;
        begin
            patch16 = d;
            patch16[16*w +: 16] = {v[7:0], v[15:8]};
        end
    endfunction

    localparam  EW = (CW > 11) ? CW : 11;
    wire [EW-1:0] eg_e  = eg_b;     // both zero-extended to EW bits
    wire [EW-1:0] ip_be = q_ip_pos[13:3];
    wire [EW-1:0] l4_be = q_l4_pos[13:3];
    wire        hit_ip = q_ip_patch && (eg_e == ip_be);
    wire        hit_l4 = q_l4_patch && (eg_e == l4_be);
    wire [63:0] d_ip   = hit_ip ? patch16(buf_q[63:0], q_ip_pos[2:1], q_ip_csum)
                                : buf_q[63:0];

    assign m_axis_tvalid = buf_v && meta_v;
    assign m_axis_tdata  = hit_l4 ? patch16(d_ip, q_l4_pos[2:1], q_l4_csum) : d_ip;
    assign m_axis_tkeep  = buf_q[71:64];
    assign m_axis_tlast  = buf_q[72];
    assign m_axis_tuser  = buf_q[73];
    assign m_drop        = q_drop;
    assign buf_pop       = m_axis_tvalid && m_axis_tready;
    assign meta_pop      = buf_pop && buf_q[72];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            eg_b <= {CW{1'b0}};
        else if (buf_pop)
            eg_b <= buf_q[72] ? {CW{1'b0}} : eg_b + 1'b1;
    end

endmodule
