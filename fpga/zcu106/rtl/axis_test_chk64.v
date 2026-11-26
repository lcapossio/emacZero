// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// axis_test_chk64.v - checker for axis_test_gen64 frames out of the 10G RX
// MAC (64-bit AXIS, FCS removed, no backpressure)
//
// Every frame is checked whole: addresses, EtherType, the length field
// against the bytes received, seq against ~seq, every payload byte against
// the xorshift stream seeded from seq, and tuser clear. With udp set the
// frames must be axis_test_gen64's UDP datagrams instead: every IPv4 and UDP
// header field (version, IHL, DF, TTL, protocol, addresses, ports, UDP
// checksum 0), the IPv4 header checksum, the IPv4 total length against the
// bytes received and the UDP length against it, seq[15:0] against the
// identification and seq[31:16] against its complement, then the payload as
// above. udp is taken at each frame's first beat. good_frames / bad_frames
// count the verdicts; tuser_frames the frames the MAC flagged; seq_gaps the
// frames whose seq is not one more than the last good-header frame's (one
// with every check up to and including seq passed; the first frame after
// reset or clear is not counted). The AXIS input is registered once (one
// cycle of latency) so the RX FIFO's RAM output does not feed the checks.
// Verilog 2001
// =============================================================================

module axis_test_chk64 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,
    input  wire        udp,

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

    localparam [63:0] HDR0  = {8'h00, 8'h02, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h02};
    localparam [47:0] HDR1  = {8'hB5, 8'h88, 8'h02, 8'h00, 8'h00, 8'h00};
    // UDP frames: beat 1 whole, beat 2 [63:32], beat 3 [63:16], beat 4 [47:0]
    localparam [63:0] UHDR1 = {8'h00, 8'h45, 8'h00, 8'h08, 8'h02, 8'h00, 8'h00, 8'h00};
    localparam [31:0] UHDR2 = {8'h11, 8'h40, 8'h00, 8'h40};
    localparam [47:0] UHDR3 = {8'h00, 8'h0A, 8'h02, 8'h00, 8'h00, 8'h0A};
    localparam [47:0] UHDR4 = {8'h89, 8'h13, 8'h89, 8'h13, 8'h01, 8'h00};

    // registered input
    reg [63:0] i_tdata;
    reg [7:0]  i_tkeep;
    reg        i_tvalid, i_tlast, i_tuser;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_tdata  <= 64'd0;
            i_tkeep  <= 8'd0;
            i_tvalid <= 1'b0;
            i_tlast  <= 1'b0;
            i_tuser  <= 1'b0;
        end else begin
            i_tdata  <= s_axis_tdata;
            i_tkeep  <= s_axis_tkeep;
            i_tvalid <= s_axis_tvalid;
            i_tlast  <= s_axis_tlast;
            i_tuser  <= s_axis_tuser;
        end
    end

    reg [12:0] beat;
    reg [15:0] bytes;               // bytes of this frame before this beat
    reg [15:0] flen;                // expected frame length
    reg        fudp;                // this frame is checked as UDP
    reg [15:0] ip_id;               // UDP: identification (beat 2)
    reg [17:0] ip_ps;               // UDP: 0xD914 + total length + id (beat 2)
    reg [15:0] ip_ul;               // UDP: expected UDP length (beat 2)
    reg [63:0] exp;
    reg        bad;
    reg        have_seq;
    reg [31:0] last_seq;

    // byte mask of this beat
    reg [63:0] m;
    integer    k;
    always @(*)
        for (k = 0; k < 8; k = k + 1)
            m[8*k +: 8] = {8{i_tkeep[k]}};

    reg [3:0] nkeep;
    always @(*) begin
        nkeep = 4'd0;
        for (k = 0; k < 8; k = k + 1)
            nkeep = nkeep + {3'd0, i_tkeep[k]};
    end

    wire        u        = (beat == 13'd0) ? udp : fudp;
    wire [12:0] seq_beat = u ? 13'd5 : 13'd2;
    wire [31:0] r_seq    = u ? i_tdata[47:16] : i_tdata[31:0];

    // big-endian 16-bit fields of this beat
    wire [15:0] be0 = {i_tdata[7:0],   i_tdata[15:8]};
    wire [15:0] be1 = {i_tdata[23:16], i_tdata[31:24]};
    wire [15:0] be3 = {i_tdata[55:48], i_tdata[63:56]};

    // IPv4 header sum with the received checksum (beat 3): the constant
    // words sum to 0xD914 (checked field by field), so a good header folds
    // to 0xFFFF
    wire [17:0] ip_s = ip_ps + {2'b00, be0};
    wire [16:0] ip_f = {1'b0, ip_s[15:0]} + {15'd0, ip_s[17:16]};
    wire [15:0] ip_v = ip_f[15:0] + {15'd0, ip_f[16]};

    // mismatch on this beat (header fields and payload)
    reg beat_bad;
    always @(*) begin
        if (!u)
            case (beat)
                13'd0:   beat_bad = i_tlast || (i_tdata != HDR0);
                13'd1:   beat_bad = i_tlast || (i_tdata[47:0] != HDR1);
                13'd2:   beat_bad = (i_tdata[63:32] != ~r_seq) ||
                                    (i_tlast && i_tkeep != 8'hFF);
                default: beat_bad = ((i_tdata ^ exp) & m) != 64'd0;
            endcase
        else
            case (beat)
                13'd0:   beat_bad = i_tlast || (i_tdata != HDR0);
                13'd1:   beat_bad = i_tlast || (i_tdata != UHDR1);
                13'd2:   beat_bad = i_tlast || (i_tdata[63:32] != UHDR2);
                13'd3:   beat_bad = i_tlast || (i_tdata[63:16] != UHDR3) ||
                                    (ip_v != 16'hFFFF);
                13'd4:   beat_bad = i_tlast || (i_tdata[47:0] != UHDR4) ||
                                    (be3 != ip_ul);
                13'd5:   beat_bad = (i_tdata[15:0] != 16'h0000) ||
                                    (i_tdata[63:48] != ~r_seq[31:16]) ||
                                    (r_seq[15:0] != ip_id) ||
                                    (i_tlast && i_tkeep != 8'hFF);
                default: beat_bad = ((i_tdata ^ exp) & m) != 64'd0;
            endcase
    end

    wire [15:0] rlen    = {i_tdata[55:48], i_tdata[63:56]};
    wire [15:0] tot     = bytes + {12'd0, nkeep};
    wire [15:0] the_len = (beat == 13'd1 && !u) ? rlen : flen;

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
            fudp         <= 1'b0;
            ip_id        <= 16'd0;
            ip_ps        <= 18'd0;
            ip_ul        <= 16'd0;
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
            if (i_tvalid) begin
                if (beat == 13'd0)
                    fudp <= udp;
                if (beat == 13'd1 && !u)
                    flen <= rlen;
                if (beat == 13'd2 && u) begin
                    ip_id <= be1;
                    ip_ps <= 18'h0D914 + {2'b00, be0} + {2'b00, be1};
                    ip_ul <= be0 - 16'd20;
                    flen  <= be0 + 16'd14;
                end
                if (beat == seq_beat) begin
                    exp <= xs({r_seq, ~r_seq});
                    if (!beat_bad && !bad) begin
                        if (have_seq && r_seq != last_seq + 32'd1 && !clear)
                            seq_gaps <= seq_gaps + 32'd1;
                        have_seq <= 1'b1;
                        last_seq <= r_seq;
                    end
                end else if (beat > seq_beat) begin
                    exp <= xs(exp);
                end
                if (i_tlast) begin
                    beat  <= 13'd0;
                    bytes <= 16'd0;
                    bad   <= 1'b0;
                    if (bad || beat_bad || i_tuser || tot != the_len ||
                        beat < seq_beat) begin
                        if (!clear) bad_frames <= bad_frames + 32'd1;
                        bad_pulse <= 1'b1;
                    end else begin
                        if (!clear) good_frames <= good_frames + 32'd1;
                        good_pulse <= 1'b1;
                    end
                    if (i_tuser && !clear)
                        tuser_frames <= tuser_frames + 32'd1;
                end else begin
                    beat  <= (beat == 13'h1FFF) ? beat : beat + 13'd1;
                    bytes <= tot;
                    bad   <= bad || beat_bad || (i_tkeep != 8'hFF);
                end
            end
        end
    end

endmodule
