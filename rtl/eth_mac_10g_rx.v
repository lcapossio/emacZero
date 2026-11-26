// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_mac_10g_rx.v - 10 Gb/s Ethernet receive MAC, 64-bit XGMII to 64-bit
// AXIS (IEEE 802.3 clauses 4 and 46), for the 10GBASE-R PCS (pcs10gbr.v).
//
// Input: one XGMII word per xgmii_rx_valid (the PCS's decoder output).
// A frame starts with the start character in lane 0 or lane 4 and ends at
// the terminate character. Frames that start in lane 4 are realigned so the
// destination address lands in lane 0 of the first output beat.
//
// Output (AXIS, no backpressure: put a FIFO behind it):
//   the frame from the destination address to the end of the payload, the
//   preamble, SFD and FCS removed; bytes in lanes 0..7, lane 0 first; tkeep
//   all ones except on the tlast beat (contiguous from lane 0). A frame with
//   any error is delivered whole with tuser set on its tlast beat, and the
//   consumer must drop it:
//     bad FCS; fewer than 64 bytes (FCS included); more than the size limit;
//     an error character inside the frame (the PCS sends them for a bad
//     block); a frame cut short by any other control character (idle,
//     ordered set, start) instead of a terminate; a start not preceded by
//     four idles or a sequence ordered set; an SFD that is not D5.
//   A frame with no payload byte (4 bytes or fewer after the SFD) produces
//   no output, only stat_done. A frame that runs past 16376 bytes without a
//   terminate is cut there, with tuser, and the rest is ignored.
//
// Size limit (bytes after the SFD, FCS included, as eth_mac_rx.v): 1518, or
// 1522 with an 802.1Q / 802.1ad tag; jumbo_en raises it to MAX_FRAME_JUMBO.
//
// Two stages: the normalizer turns XGMII words into frame words (start,
// data, end with byte count), shifting lane-4 frames by four bytes; the frame
// stage runs the CRC, holds one word back to strip the FCS and sends the
// last beat and the stats one cycle after the end word.
// Verilog 2001
// =============================================================================

module eth_mac_10g_rx #(
    parameter MAX_FRAME_STD   = 1518,
    parameter MAX_FRAME_JUMBO = 9018
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [63:0] xgmii_rxd,
    input  wire [7:0]  xgmii_rxc,
    input  wire        xgmii_rx_valid,

    input  wire        jumbo_en,

    output reg  [63:0] m_axis_tdata,
    output reg  [7:0]  m_axis_tkeep,
    output reg         m_axis_tvalid,
    output reg         m_axis_tlast,
    output reg         m_axis_tuser,

    // Per-frame pulses, one cycle, one cycle after the frame's last beat
    output reg         stat_done,
    output reg  [13:0] stat_len,          // bytes after the SFD, FCS included
    output reg         stat_err_fcs,
    output reg         stat_err_ctl,      // control character or bad SFD
    output reg         stat_err_oversize,
    output reg         stat_err_undersize,
    output reg         stat_is_bcast,
    output reg         stat_is_mcast
);

    localparam [7:0]  C_START = 8'hFB, C_TERM = 8'hFD, C_ERR = 8'hFE,
                      C_IDLE = 8'h07, C_SEQ = 8'h9C, SFD = 8'hD5;
    localparam [31:0] RESIDUE = 32'hDEBB20E3;   // CRC register over frame + FCS
    localparam [10:0] CAP_WORDS = 11'd2047;      // 16376 bytes

    // =========================================================================
    // Normalizer
    // =========================================================================
    localparam K_START = 2'd0, K_DATA = 2'd1, K_END = 2'd2;
    localparam N_IDLE = 2'd0, N_PRE4 = 2'd1, N_FRAME = 2'd2, N_DISCARD = 2'd3;

    reg [1:0]  n_st;
    reg        off4;
    reg [31:0] hold;
    reg [3:0]  holdc;
    reg [10:0] wcnt;
    reg        def_v;               // an end word is owed (lane-4 frame whose
    reg [31:0] def_d;               // terminate was in lanes 4..7)
    reg [2:0]  def_n;
    reg        def_err;

    reg        it_v;
    reg [1:0]  it_k;
    reg [63:0] it_d;
    reg [3:0]  it_n;
    reg        it_err;

    // End of a frame: the lowest lane holding a control character other
    // than an error character. A terminate ends the frame normally; anything
    // else (idle, ordered set, start) ends it abnormally (t_bad), and the
    // frame is delivered with tuser. Error characters below it (the control
    // lanes under the mask) only mark the frame bad.
    reg        t_any;
    reg        t_bad;
    reg [2:0]  t_lane;
    reg [7:0]  below;               // mask of the lanes below the end
    integer    k;
    always @(*) begin
        t_any  = 1'b0;
        t_bad  = 1'b0;
        t_lane = 3'd0;
        for (k = 7; k >= 0; k = k - 1)
            if (xgmii_rxc[k] && xgmii_rxd[8*k +: 8] != C_ERR) begin
                t_any  = 1'b1;
                t_bad  = xgmii_rxd[8*k +: 8] != C_TERM;
                t_lane = k[2:0];
            end
        for (k = 0; k < 8; k = k + 1)
            below[k] = !t_any || (k < t_lane);
    end

    // A start must follow a column of four idles or a sequence ordered set
    // (clause 46.3.3.2): lanes 4..7 of the previous word for a lane-0 start,
    // lanes 0..3 of the same word for a lane-4 start. A frame whose start
    // does not is delivered with tuser.
    function col_idle;
        input [31:0] d;
        input [3:0]  c;
        begin
            col_idle = (c == 4'hF && d == {4{C_IDLE}}) ||
                       (c == 4'h1 && d[7:0] == C_SEQ);
        end
    endfunction
    reg  prev_hi_idle;              // lanes 4..7 of the previous word
    wire lo_idle = col_idle(xgmii_rxd[31:0], xgmii_rxc[3:0]);
    reg  pre4_err;

    wire start0 = xgmii_rxc[0] && xgmii_rxd[7:0]   == C_START;
    wire start4 = xgmii_rxc[4] && xgmii_rxd[39:32] == C_START;

    wire [63:0] w4  = {xgmii_rxd[31:0], hold};     // lane-4 frame, shifted
    wire [7:0]  w4c = {xgmii_rxc[3:0], holdc};
    wire [7:0]  ctl_below = xgmii_rxc & below;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_st    <= N_IDLE;
            off4    <= 1'b0;
            hold    <= 32'd0;
            holdc   <= 4'd0;
            wcnt    <= 11'd0;
            def_v   <= 1'b0;
            def_d   <= 32'd0;
            def_n   <= 3'd0;
            def_err <= 1'b0;
            it_v    <= 1'b0;
            it_k    <= K_DATA;
            it_d    <= 64'd0;
            it_n    <= 4'd0;
            it_err  <= 1'b0;
            prev_hi_idle <= 1'b0;
            pre4_err     <= 1'b0;
        end else begin
            it_v <= 1'b0;
            if (xgmii_rx_valid)
                prev_hi_idle <= col_idle(xgmii_rxd[63:32], xgmii_rxc[7:4]);
            if (def_v) begin
                it_v   <= 1'b1;
                it_k   <= K_END;
                it_d   <= {32'd0, def_d};
                it_n   <= {1'b0, def_n};
                it_err <= def_err;
                def_v  <= 1'b0;
            end
            if (xgmii_rx_valid) begin
                case (n_st)
                    N_IDLE, N_DISCARD: begin
                        // a lane-0 start right after an owed end word would be
                        // a gap of 4 bytes or less: not a frame, ignored.
                        // N_DISCARD (after a runaway frame was cut) also
                        // waits here, for a terminate, idles or a start.
                        if (start0 && !def_v) begin
                            it_v   <= 1'b1;
                            it_k   <= K_START;
                            it_d   <= xgmii_rxd;
                            it_n   <= 4'd8;
                            it_err <= (|xgmii_rxc[7:1]) || !prev_hi_idle;
                            off4   <= 1'b0;
                            wcnt   <= 11'd0;
                            n_st   <= N_FRAME;
                        end else if (start4) begin
                            hold     <= xgmii_rxd[63:32];
                            holdc    <= xgmii_rxc[7:4];
                            pre4_err <= !lo_idle;
                            n_st     <= N_PRE4;
                        end else if (t_any || &xgmii_rxc) begin
                            n_st  <= N_IDLE;
                        end
                    end

                    N_PRE4: begin
                        it_v   <= 1'b1;
                        it_k   <= K_START;
                        it_d   <= w4;
                        it_n   <= 4'd8;
                        it_err <= (|w4c[7:1]) || pre4_err;
                        hold   <= xgmii_rxd[63:32];
                        holdc  <= xgmii_rxc[7:4];
                        off4   <= 1'b1;
                        wcnt   <= 11'd0;
                        n_st   <= N_FRAME;
                        if (t_any) begin
                            // a frame of 0 to 3 bytes ends in this word (or
                            // the preamble itself is cut short: an error)
                            def_v   <= 1'b1;
                            def_d   <= xgmii_rxd[63:32];
                            def_n   <= t_lane[2] ? {1'b0, t_lane[1:0]} : 3'd0;
                            def_err <= !t_lane[2] || t_bad || (|ctl_below[7:4]);
                            n_st    <= N_IDLE;
                        end
                    end

                    N_FRAME: begin
                        it_v <= 1'b1;
                        hold  <= xgmii_rxd[63:32];
                        holdc <= xgmii_rxc[7:4];
                        if (!t_any && wcnt == CAP_WORDS) begin
                            it_k   <= K_END;          // runaway: cut it here
                            it_d   <= 64'd0;
                            it_n   <= 4'd0;
                            it_err <= 1'b1;
                            n_st   <= N_DISCARD;
                        end else if (!off4) begin
                            it_d   <= xgmii_rxd;
                            it_err <= (|ctl_below) || t_bad;
                            if (t_any) begin
                                it_k <= K_END;
                                it_n <= {1'b0, t_lane};
                                n_st <= N_IDLE;
                            end else begin
                                it_k <= K_DATA;
                                it_n <= 4'd8;
                                wcnt <= wcnt + 11'd1;
                            end
                        end else begin
                            it_d <= w4;
                            if (t_any && !t_lane[2]) begin
                                it_k   <= K_END;
                                it_n   <= {2'b01, t_lane[1:0]};
                                it_err <= (|holdc) || (|ctl_below[3:0]) || t_bad;
                                n_st   <= N_IDLE;
                            end else begin
                                it_k   <= K_DATA;
                                it_n   <= 4'd8;
                                it_err <= (|holdc) || (|xgmii_rxc[3:0]);
                                wcnt   <= wcnt + 11'd1;
                                if (t_any) begin       // terminate in lanes 4..7
                                    def_v   <= 1'b1;
                                    def_d   <= xgmii_rxd[63:32];
                                    def_n   <= {1'b0, t_lane[1:0]};
                                    def_err <= (|ctl_below[7:4]) || t_bad;
                                    n_st    <= N_IDLE;
                                end
                            end
                        end
                    end

                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // Frame stage
    // =========================================================================
    reg        f_in;
    reg [31:0] crc;
    reg [13:0] cnt;                 // bytes of the frame's data words so far
    reg        held_v;
    reg [63:0] held;
    reg        err_acc;
    reg        vlan, bcast, mcast;

    reg        fin_v;               // a frame ended last cycle
    reg        fin_out;             // ... and its last beat is owed
    reg [63:0] fin_d;
    reg [7:0]  fin_keep;
    reg        fin_bad;
    reg [13:0] fin_len;
    reg        fin_fcs, fin_ctl, fin_over, fin_under, fin_bc, fin_mc;

    wire [31:0] crc_next;
    crc32_d64 u_crc (.crc_in (crc), .data (it_d),
                     .nbytes (it_k == K_END ? it_n : 4'd8), .crc_out (crc_next));

    // end-word checks
    wire [14:0] e_len   = {1'b0, cnt} + {11'd0, it_n};
    wire [13:0] e_len_s = e_len[14] ? 14'h3FFF : e_len[13:0];
    wire [13:0] e_max   = jumbo_en ? MAX_FRAME_JUMBO[13:0]
                        : vlan     ? MAX_FRAME_STD[13:0] + 14'd4
                        :            MAX_FRAME_STD[13:0];
    wire        e_fcs   = crc_next != RESIDUE;
    wire        e_ctl   = err_acc || it_err;
    wire        e_under = e_len_s < 14'd64;
    wire        e_over  = e_len_s > e_max;
    // destination address for a frame with no data word before its end word
    wire [47:0] e_dst   = (cnt == 14'd0) ? it_d[47:0] : 48'd0;

    function [7:0] keep_n;
        input [3:0] n;
        integer     j;
        begin
            for (j = 0; j < 8; j = j + 1)
                keep_n[j] = (j < n);
        end
    endfunction

    wire tpid = (it_d[39:32] == 8'h81 && it_d[47:40] == 8'h00) ||
                (it_d[39:32] == 8'h88 && it_d[47:40] == 8'hA8);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_in      <= 1'b0;
            crc       <= 32'hFFFFFFFF;
            cnt       <= 14'd0;
            held_v    <= 1'b0;
            held      <= 64'd0;
            err_acc   <= 1'b0;
            vlan      <= 1'b0;
            bcast     <= 1'b0;
            mcast     <= 1'b0;
            fin_v     <= 1'b0;
            fin_out   <= 1'b0;
            fin_d     <= 64'd0;
            fin_keep  <= 8'd0;
            fin_bad   <= 1'b0;
            fin_len   <= 14'd0;
            fin_fcs   <= 1'b0;
            fin_ctl   <= 1'b0;
            fin_over  <= 1'b0;
            fin_under <= 1'b0;
            fin_bc    <= 1'b0;
            fin_mc    <= 1'b0;
            m_axis_tdata  <= 64'd0;
            m_axis_tkeep  <= 8'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
            stat_done          <= 1'b0;
            stat_len           <= 14'd0;
            stat_err_fcs       <= 1'b0;
            stat_err_ctl       <= 1'b0;
            stat_err_oversize  <= 1'b0;
            stat_err_undersize <= 1'b0;
            stat_is_bcast      <= 1'b0;
            stat_is_mcast      <= 1'b0;
        end else begin
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
            stat_done     <= 1'b0;
            fin_v         <= 1'b0;
            fin_out       <= 1'b0;

            // the previous end word's last beat and stats
            if (fin_v) begin
                if (fin_out) begin
                    m_axis_tdata  <= fin_d;
                    m_axis_tkeep  <= fin_keep;
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= 1'b1;
                    m_axis_tuser  <= fin_bad;
                end
                stat_done          <= 1'b1;
                stat_len           <= fin_len;
                stat_err_fcs       <= fin_fcs;
                stat_err_ctl       <= fin_ctl;
                stat_err_oversize  <= fin_over;
                stat_err_undersize <= fin_under;
                stat_is_bcast      <= fin_bc;
                stat_is_mcast      <= fin_mc;
            end

            if (it_v) begin
                case (it_k)
                    K_START: begin
                        f_in    <= 1'b1;
                        crc     <= 32'hFFFFFFFF;
                        cnt     <= 14'd0;
                        held_v  <= 1'b0;
                        err_acc <= it_err || (it_d[63:56] != SFD);
                        vlan    <= 1'b0;
                        bcast   <= 1'b0;
                        mcast   <= 1'b0;
                    end

                    K_DATA: if (f_in) begin
                        crc     <= crc_next;
                        cnt     <= (cnt > 14'h3FF7) ? 14'h3FFF : cnt + 14'd8;
                        err_acc <= err_acc || it_err;
                        held    <= it_d;
                        held_v  <= 1'b1;
                        if (held_v) begin
                            m_axis_tdata  <= held;
                            m_axis_tkeep  <= 8'hFF;
                            m_axis_tvalid <= 1'b1;
                        end
                        if (cnt == 14'd0) begin
                            bcast <= (it_d[47:0] == 48'hFFFFFFFFFFFF);
                            mcast <= it_d[0] && (it_d[47:0] != 48'hFFFFFFFFFFFF);
                        end
                        if (cnt == 14'd8)
                            vlan <= tpid;
                    end

                    default: if (f_in) begin    // K_END
                        f_in      <= 1'b0;
                        held_v    <= 1'b0;
                        fin_v     <= 1'b1;
                        fin_bad   <= e_fcs || e_ctl || e_under || e_over;
                        fin_len   <= e_len_s;
                        fin_fcs   <= e_fcs;
                        fin_ctl   <= e_ctl;
                        fin_over  <= e_over;
                        fin_under <= e_under;
                        fin_bc    <= (cnt == 14'd0) ? (e_dst == 48'hFFFFFFFFFFFF
                                                       && it_n >= 4'd6)
                                                    : bcast;
                        fin_mc    <= (cnt == 14'd0) ? (e_dst[0] && e_dst != 48'hFFFFFFFFFFFF
                                                       && it_n >= 4'd6)
                                                    : mcast;
                        if (it_n >= 4'd5) begin
                            // the held word goes now, the end word's payload
                            // bytes are the last beat
                            if (held_v) begin
                                m_axis_tdata  <= held;
                                m_axis_tkeep  <= 8'hFF;
                                m_axis_tvalid <= 1'b1;
                            end
                            fin_out  <= 1'b1;
                            fin_d    <= it_d;
                            fin_keep <= keep_n(it_n - 4'd4);
                        end else begin
                            // the FCS starts in the held word (or the frame
                            // has no payload at all)
                            fin_out  <= held_v;
                            fin_d    <= held;
                            fin_keep <= keep_n(it_n + 4'd4);
                        end
                    end
                endcase
            end
        end
    end

endmodule
