// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// axis_test_chk64.v - checker for axis_test_gen64 frames out of the 10G RX
// MAC (64-bit AXIS, FCS removed, no backpressure)
//
// Every frame is checked whole: addresses, EtherType, the length field
// against the bytes received, seq against ~seq, every payload byte against
// the xorshift stream seeded from seq, and tuser clear. good_frames /
// bad_frames count the verdicts; tuser_frames the frames the MAC flagged;
// seq_gaps the frames whose seq is not one more than the last good-header
// frame's (the first frame after reset or clear is not counted).
// Verilog 2001
// =============================================================================

module axis_test_chk64 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,

    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    output reg  [31:0] good_frames,
    output reg  [31:0] bad_frames,
    output reg  [31:0] tuser_frames,
    output reg  [31:0] seq_gaps,
    output reg         good_pulse,
    output reg         bad_pulse
);

    function [63:0] xs;
        input [63:0] s;
        reg   [63:0] t;
        begin
            t  = s ^ (s << 13);
            t  = t ^ (t >> 7);
            xs = t ^ (t << 17);
        end
    endfunction

    localparam [63:0] HDR0 = {8'h00, 8'h02, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h02};
    localparam [47:0] HDR1 = {8'hB5, 8'h88, 8'h02, 8'h00, 8'h00, 8'h00};

    reg [12:0] beat;
    reg [15:0] bytes;               // bytes of this frame before this beat
    reg [15:0] flen;
    reg [63:0] exp;
    reg        bad;
    reg        have_seq;
    reg [31:0] last_seq;

    // byte mask of this beat
    reg [63:0] m;
    integer    k;
    always @(*)
        for (k = 0; k < 8; k = k + 1)
            m[8*k +: 8] = {8{s_axis_tkeep[k]}};

    reg [3:0] nkeep;
    always @(*) begin
        nkeep = 4'd0;
        for (k = 0; k < 8; k = k + 1)
            nkeep = nkeep + {3'd0, s_axis_tkeep[k]};
    end

    wire [31:0] r_seq = s_axis_tdata[31:0];

    // mismatch on this beat (header fields and payload)
    reg beat_bad;
    always @(*) begin
        case (beat)
            13'd0:   beat_bad = s_axis_tlast || (s_axis_tdata != HDR0);
            13'd1:   beat_bad = s_axis_tlast || (s_axis_tdata[47:0] != HDR1);
            13'd2:   beat_bad = (s_axis_tdata[63:32] != ~r_seq) ||
                                (s_axis_tlast && s_axis_tkeep != 8'hFF);
            default: beat_bad = ((s_axis_tdata ^ exp) & m) != 64'd0;
        endcase
    end

    wire [15:0] rlen    = {s_axis_tdata[55:48], s_axis_tdata[63:56]};
    wire [15:0] tot     = bytes + {12'd0, nkeep};
    wire [15:0] the_len = (beat == 13'd1) ? rlen : flen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            good_frames  <= 32'd0;
            bad_frames   <= 32'd0;
            tuser_frames <= 32'd0;
            seq_gaps     <= 32'd0;
            good_pulse   <= 1'b0;
            bad_pulse    <= 1'b0;
            beat         <= 13'd0;
            bytes        <= 16'd0;
            flen         <= 16'd0;
            exp          <= 64'd0;
            bad          <= 1'b0;
            have_seq     <= 1'b0;
            last_seq     <= 32'd0;
        end else begin
            good_pulse <= 1'b0;
            bad_pulse  <= 1'b0;
            if (clear) begin
                good_frames  <= 32'd0;
                bad_frames   <= 32'd0;
                tuser_frames <= 32'd0;
                seq_gaps     <= 32'd0;
                have_seq     <= 1'b0;
            end
            if (s_axis_tvalid) begin
                if (beat == 13'd1)
                    flen <= rlen;
                if (beat == 13'd2) begin
                    exp <= xs({r_seq, ~r_seq});
                    if (!beat_bad) begin
                        if (have_seq && r_seq != last_seq + 32'd1 && !clear)
                            seq_gaps <= seq_gaps + 32'd1;
                        have_seq <= 1'b1;
                        last_seq <= r_seq;
                    end
                end else if (beat > 13'd2) begin
                    exp <= xs(exp);
                end
                if (s_axis_tlast) begin
                    beat  <= 13'd0;
                    bytes <= 16'd0;
                    bad   <= 1'b0;
                    if (bad || beat_bad || s_axis_tuser || tot != the_len ||
                        beat < 13'd2) begin
                        if (!clear) bad_frames <= bad_frames + 32'd1;
                        bad_pulse <= 1'b1;
                    end else begin
                        if (!clear) good_frames <= good_frames + 32'd1;
                        good_pulse <= 1'b1;
                    end
                    if (s_axis_tuser && !clear)
                        tuser_frames <= tuser_frames + 32'd1;
                end else begin
                    beat  <= (beat == 13'h1FFF) ? beat : beat + 13'd1;
                    bytes <= tot;
                    bad   <= bad || beat_bad || (s_axis_tkeep != 8'hFF);
                end
            end
        end
    end

endmodule
