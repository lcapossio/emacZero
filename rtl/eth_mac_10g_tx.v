// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_mac_10g_tx.v - 10 Gb/s Ethernet transmit MAC, 64-bit AXIS to 64-bit
// XGMII (IEEE 802.3 clauses 4 and 46), for the 10GBASE-R PCS (pcs10gbr.v).
//
// Everything advances on ce (the PCS's xgmii_tx_ready): a word is produced on
// every ce, and the cycles without ce are not idle time on the line.
//
// Input (AXIS, clk domain):
//   one frame from the destination address to the end of the payload, no
//   FCS; bytes in lanes 0..7, lane 0 first; tkeep is all ones except on the
//   tlast beat, where it is contiguous from lane 0 (1 to 8 lanes).
//   tuser on any beat sends the frame with a wrong FCS (the CRC not
//   complemented), so the receiver drops it. Error characters are not used
//   for this: a terminate word with error characters before the terminate
//   cannot be encoded by the PCS, which would then lose the terminate.
//   The PCS takes a word on every ce, so once a frame has started its beats
//   must keep coming: feed it from a store-and-forward buffer. If a beat is
//   missing (underrun) the MAC sends a word of error characters in its place
//   and the frame continues, corrupted; stat_underrun pulses.
//
// Output:
//   start character in lane 0 or lane 4, six preamble bytes and the SFD, the
//   frame padded with zeros to 60 bytes, the FCS, the terminate character,
//   then idles. The inter-frame gap follows the deficit idle count rule of
//   clause 46.3.1.4: a frame starts at the first 4-byte column boundary
//   where the gap (terminate and idle bytes) is at least 9 + the deficit,
//   and the deficit becomes max(0, deficit + 12 - gap). Back-to-back frames
//   get gaps of 9 to 15 bytes averaging 12, which is line rate for every
//   length.
//
// Pipeline: AXIS -> B (one beat, padding, CRC including the beat) -> C (the
// chunk for the line: preamble, data, data with FCS, FCS tail) -> scheduler
// (lane 0 / lane 4 placement, terminate, gap) -> registered XGMII.
// Verilog 2001
// =============================================================================

module eth_mac_10g_tx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ce,

    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,
    output wire        s_axis_tready,

    output reg  [63:0] xgmii_txd,
    output reg  [7:0]  xgmii_txc,

    output reg         stat_tx_frame,      // a frame ended (terminate sent)
    output reg         stat_underrun       // a beat was missing mid-frame
);

    localparam [7:0]  C_IDLE = 8'h07, C_START = 8'hFB, C_TERM = 8'hFD,
                      C_ERR  = 8'hFE;
    localparam [63:0] IDLE_D = {8{C_IDLE}};
    localparam [63:0] ERR_D  = {8{C_ERR}};
    localparam [63:0] PRE_D  = {8'hD5, {6{8'h55}}, C_START};  // S, 6 x 55, SFD
    localparam [15:0] MIN_PAY = 16'd60;                // bytes before the FCS

    // =========================================================================
    // Stage B: one input beat, normalized (zero-filled, padded to 60 bytes),
    // with crc_b = CRC up to and including it
    // =========================================================================
    reg        b_valid, b_last, b_first;
    reg        b_err;       // tuser seen on this frame up to this beat
    reg [63:0] b_data;
    reg [3:0]  b_n;
    reg [31:0] b_crc;
    reg [15:0] pay_cnt;     // bytes of the current frame loaded into B so far
    reg        pad_mode;    // generating zero beats up to 60 bytes

    wire b_take;            // C takes B this ce (defined in stage C)
    wire b_free = !b_valid || b_take;

    assign s_axis_tready = ce && b_free && !pad_mode;

    // incoming beat: byte count and zero-filled data
    reg [3:0]  in_n;
    reg [63:0] in_mask;
    integer    k;
    always @(*) begin
        in_n = 4'd8;
        if (s_axis_tlast) begin
            in_n = 4'd0;
            for (k = 0; k < 8; k = k + 1)
                if (s_axis_tkeep[k]) in_n = k[3:0] + 4'd1;
        end
        for (k = 0; k < 8; k = k + 1)
            in_mask[8*k +: 8] = (k < in_n) ? 8'hFF : 8'h00;
    end

    // what B loads when it is free
    reg        nb_load, nb_last, nb_err, nb_pad;
    reg [63:0] nb_data;
    reg [3:0]  nb_n;
    wire [15:0] room = MIN_PAY - pay_cnt;   // pad bytes still owed (if > 0)
    always @(*) begin
        nb_load = 1'b0; nb_last = 1'b0; nb_err = 1'b0; nb_pad = pad_mode;
        nb_data = 64'd0; nb_n = 4'd8;
        if (pad_mode) begin
            nb_load = 1'b1;
            if (pay_cnt + 16'd8 >= MIN_PAY) begin
                nb_n    = room[3:0];
                nb_last = 1'b1;
                nb_pad  = 1'b0;
            end
        end else if (s_axis_tvalid) begin
            nb_load = 1'b1;
            nb_err  = s_axis_tuser;
            nb_data = s_axis_tdata & in_mask;
            nb_n    = in_n;
            if (s_axis_tlast) begin
                if (pay_cnt + {12'd0, in_n} >= MIN_PAY) begin
                    nb_last = 1'b1;
                end else if (pay_cnt + 16'd8 >= MIN_PAY) begin
                    nb_n    = room[3:0];         // this beat reaches 60 bytes
                    nb_last = 1'b1;
                end else begin
                    nb_n    = 4'd8;              // pad the rest of the beat
                    nb_pad  = 1'b1;
                end
            end
        end
    end

    wire        nb_first = (pay_cnt == 16'd0);
    wire [31:0] crc_prev = nb_first ? 32'hFFFFFFFF : b_crc;
    wire [31:0] nb_crc;
    crc32_d64 u_crc (.crc_in (crc_prev), .data (nb_data), .nbytes (nb_n),
                     .crc_out (nb_crc));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_valid  <= 1'b0;
            b_last   <= 1'b0;
            b_first  <= 1'b0;
            b_err    <= 1'b0;
            b_data   <= 64'd0;
            b_n      <= 4'd0;
            b_crc    <= 32'hFFFFFFFF;
            pay_cnt  <= 16'd0;
            pad_mode <= 1'b0;
        end else if (ce && b_free) begin
            b_valid <= nb_load;
            if (nb_load) begin
                b_last   <= nb_last;
                b_first  <= nb_first;
                b_err    <= nb_err || (b_err && !nb_first);
                b_data   <= nb_data;
                b_n      <= nb_n;
                b_crc    <= nb_crc;
                pad_mode <= nb_pad;
                pay_cnt  <= nb_last ? 16'd0
                          : (pay_cnt == 16'hFFFF) ? pay_cnt
                          : pay_cnt + {12'd0, nb_n};
            end
        end
    end

    // =========================================================================
    // Stage C: the chunk the scheduler sends next
    // =========================================================================
    reg        c_valid, c_last, c_pre;
    reg [63:0] c_data;
    reg [7:0]  c_ctl;
    reg [3:0]  c_n;
    reg        ft_valid;            // FCS tail chunk pending
    reg [31:0] ft_data;
    reg [3:0]  ft_n;
    reg        b_pre_done;          // preamble already sent for the beat in B

    wire c_take;                    // the scheduler takes C this ce
    wire c_free = !c_valid || c_take;

    // B with the FCS appended after its last byte: {fcs, data} >> 0, fcs at
    // byte b_n; bytes 8..11 spill into the FCS tail
    // a frame with tuser on any beat gets the uncomplemented CRC: a wrong FCS
    wire [31:0] fcs = b_err ? b_crc : ~b_crc;
    wire [95:0] with_fcs = {32'd0, b_data} | ({64'd0, fcs} << {b_n, 3'b000});

    assign b_take = ce && c_free && !ft_valid && b_valid && !(b_first && !b_pre_done);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_valid    <= 1'b0;
            c_last     <= 1'b0;
            c_pre      <= 1'b0;
            c_data     <= IDLE_D;
            c_ctl      <= 8'h00;
            c_n        <= 4'd0;
            ft_valid   <= 1'b0;
            ft_data    <= 32'd0;
            ft_n       <= 4'd0;
            b_pre_done <= 1'b0;
        end else if (ce && c_free) begin
            c_pre <= 1'b0;
            if (ft_valid) begin
                c_valid  <= 1'b1;
                c_data   <= {32'd0, ft_data};
                c_ctl    <= 8'h00;
                c_n      <= ft_n;
                c_last   <= 1'b1;
                ft_valid <= 1'b0;
            end else if (b_valid && b_first && !b_pre_done) begin
                c_valid    <= 1'b1;
                c_data     <= PRE_D;
                c_ctl      <= 8'h01;
                c_n        <= 4'd8;
                c_last     <= 1'b0;
                c_pre      <= 1'b1;
                b_pre_done <= 1'b1;
            end else if (b_valid) begin
                b_pre_done <= 1'b0;
                c_valid    <= 1'b1;
                c_ctl      <= 8'h00;
                if (!b_last) begin
                    c_data <= b_data;
                    c_n    <= 4'd8;
                    c_last <= 1'b0;
                end else if (b_n <= 4'd4) begin
                    c_data <= with_fcs[63:0];
                    c_n    <= b_n + 4'd4;
                    c_last <= 1'b1;
                end else begin
                    c_data   <= with_fcs[63:0];
                    c_n      <= 4'd8;
                    c_last   <= 1'b0;
                    ft_valid <= 1'b1;
                    ft_data  <= with_fcs[95:64];
                    ft_n     <= b_n - 4'd4;
                end
            end else begin
                c_valid <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Scheduler: lane placement, terminate, gap with deficit idle count
    // =========================================================================
    localparam S_IDLE = 2'd0, S_DATA = 2'd1, S_TAIL = 2'd2;
    reg [1:0]  st;
    reg        off4;              // current frame started in lane 4
    reg [31:0] hold;              // upper half of the previous chunk (off4)
    reg [3:0]  hold_c;
    reg [2:0]  tail_n;            // bytes of hold left before the terminate
    reg [5:0]  gap;               // gap bytes so far (saturating)
    reg [1:0]  dic;               // deficit idle count, 0..3

    // a frame ready to start: the preamble chunk is in C
    wire avail = c_valid && c_pre;
    wire [6:0] need = 7'd9 + {5'd0, dic};
    wire [6:0] g0 = {1'b0, gap};
    wire [6:0] g4 = {1'b0, gap} + 7'd4;
    wire start0 = (st == S_IDLE) && avail && (g0 >= need);
    wire start4 = (st == S_IDLE) && avail && !start0 && (g4 >= need);

    assign c_take = ce && (start0 || start4 || (st == S_DATA && c_valid));

    // data[k] / ctl[k] below lane t, terminate at lane t, idles above
    function [71:0] term_word;    // {ctl, data}
        input [63:0] d;
        input [7:0]  c;
        input [3:0]  t;
        integer      j;
        reg   [63:0] od;
        reg   [7:0]  oc;
        begin
            for (j = 0; j < 8; j = j + 1) begin
                if (j < t)       begin od[8*j +: 8] = d[8*j +: 8]; oc[j] = c[j]; end
                else if (j == t) begin od[8*j +: 8] = C_TERM;      oc[j] = 1'b1; end
                else             begin od[8*j +: 8] = C_IDLE;      oc[j] = 1'b1; end
            end
            term_word = {oc, od};
        end
    endfunction

    function [1:0] dic_next;      // max(0, dic + 12 - g), g >= 9 + dic
        input [1:0] d;
        input [6:0] g;
        reg   [7:0] v;
        begin
            v = 8'd12 + {6'd0, d};
            dic_next = (v > {1'b0, g}) ? (v[1:0] - g[1:0]) : 2'd0;
        end
    endfunction

    wire [71:0] tw_off0  = term_word(c_data, c_ctl, c_n);
    wire [71:0] tw_off4  = term_word({c_data[31:0], hold}, {c_ctl[3:0], hold_c},
                                     c_n + 4'd4);
    wire [71:0] tw_tail  = term_word({32'd0, hold}, {4'd0, hold_c}, {1'b0, tail_n});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st            <= S_IDLE;
            off4          <= 1'b0;
            hold          <= 32'd0;
            hold_c        <= 4'd0;
            tail_n        <= 3'd0;
            gap           <= 6'd63;
            dic           <= 2'd0;
            xgmii_txd     <= IDLE_D;
            xgmii_txc     <= 8'hFF;
            stat_tx_frame <= 1'b0;
            stat_underrun <= 1'b0;
        end else begin
            stat_tx_frame <= 1'b0;
            stat_underrun <= 1'b0;
            if (ce) begin
                case (st)
                    S_IDLE: begin
                        if (start0) begin
                            xgmii_txd <= c_data;
                            xgmii_txc <= c_ctl;
                            off4      <= 1'b0;
                            dic       <= dic_next(dic, g0);
                            st        <= S_DATA;
                        end else if (start4) begin
                            xgmii_txd <= {c_data[31:0], IDLE_D[31:0]};
                            xgmii_txc <= {c_ctl[3:0], 4'hF};
                            hold      <= c_data[63:32];
                            hold_c    <= c_ctl[7:4];
                            off4      <= 1'b1;
                            dic       <= dic_next(dic, g4);
                            st        <= S_DATA;
                        end else begin
                            xgmii_txd <= IDLE_D;
                            xgmii_txc <= 8'hFF;
                            gap       <= (gap > 6'd55) ? 6'd63 : gap + 6'd8;
                        end
                    end

                    S_DATA: begin
                        if (!c_valid) begin
                            // underrun: error characters, the frame goes on
                            xgmii_txd     <= ERR_D;
                            xgmii_txc     <= 8'hFF;
                            stat_underrun <= 1'b1;
                        end else if (!off4) begin
                            if (!c_last) begin
                                xgmii_txd <= c_data;
                                xgmii_txc <= c_ctl;
                            end else if (c_n == 4'd8) begin
                                xgmii_txd <= c_data;
                                xgmii_txc <= c_ctl;
                                tail_n    <= 3'd0;
                                st        <= S_TAIL;
                            end else begin
                                xgmii_txd     <= tw_off0[63:0];
                                xgmii_txc     <= tw_off0[71:64];
                                gap           <= 6'd8 - {2'd0, c_n};
                                stat_tx_frame <= 1'b1;
                                st            <= S_IDLE;
                            end
                        end else begin
                            if (!c_last || c_n >= 4'd4) begin
                                xgmii_txd <= {c_data[31:0], hold};
                                xgmii_txc <= {c_ctl[3:0], hold_c};
                                hold      <= c_data[63:32];
                                hold_c    <= c_ctl[7:4];
                                if (c_last) begin
                                    tail_n <= c_n[2:0] - 3'd4;   // 0..4 (n = 8 -> 4)
                                    st     <= S_TAIL;
                                end
                            end else begin
                                xgmii_txd     <= tw_off4[63:0];
                                xgmii_txc     <= tw_off4[71:64];
                                gap           <= 6'd4 - {2'd0, c_n};
                                stat_tx_frame <= 1'b1;
                                st            <= S_IDLE;
                            end
                        end
                    end

                    default: begin   // S_TAIL
                        xgmii_txd     <= tw_tail[63:0];
                        xgmii_txc     <= tw_tail[71:64];
                        gap           <= 6'd8 - {3'd0, tail_n};
                        stat_tx_frame <= 1'b1;
                        st            <= S_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
