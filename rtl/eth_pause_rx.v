// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_pause_rx.v - 802.3x PAUSE frame recognition on the PHY receive stream
//
// Runs in the PHY receive clock domain, on the bytes as they arrive from the
// PHY (preamble and SFD included), ahead of the RX store-and-forward FIFO. A
// PAUSE frame therefore takes effect as soon as it has been received, not
// after the frames buffered ahead of it have been replayed: 802.3 Annex 31B
// gives a MAC 512 bit times (1024 at 1 Gb/s) from the end of a PAUSE frame to
// stop starting data frames.
//
// A frame is a PAUSE frame when dst = 01:80:C2:00:00:01, EtherType = 0x8808
// and opcode = 0x0001. It counts, and takes effect when it ends, only if it
// is a valid frame: good FCS, no rx_er while rx_dv is high, and at least 64
// bytes.
// Then pause_tgl flips when it ends. eth_pause crosses that into its own clock
// domain: it synchronizes pause_tgl and reads pause_quanta once the flip has
// arrived. pause_quanta takes a matched frame's pause_time as soon as those
// bytes arrive (bytes 16-17 after the SFD), so it is settled at least 46 byte
// times before the flip (the rest of the frame, FCS included) without a
// timing constraint on the crossing, and it next changes at the next matched
// frame's pause_time bytes, at least 24 byte times after the flip (preamble,
// SFD and 16 bytes, with any IFG), far longer than the synchronizer takes.
//
// Byte input:
//   RX_NIBBLE = 0  rx_d is a byte on every rx_clk cycle with rx_dv and rx_ce
//                  (GMII: rx_ce tied 1; RGMII 10/100: one byte every two
//                  cycles). rx_er counts on the cycles with rx_ce, where it
//                  goes with the byte (rgmii_if holds it in between).
//   RX_NIBBLE = 1  rx_d[3:0] is an MII nibble on every cycle with rx_dv, low
//                  nibble first; rx_ce is ignored. Nibbles are paired from
//                  the SFD, so the preamble may have an odd number of them.
// A frame is the rx_dv envelope; it ends on the first cycle with rx_dv low.
// rx_er on any of its bytes or, with RX_NIBBLE = 1, any of its nibbles (a
// trailing odd nibble included) makes the frame invalid.
//
// rst_n is asynchronous; it is synchronized to rx_clk here.
// Verilog 2001
// =============================================================================

module eth_pause_rx #(
    parameter RX_NIBBLE = 0
)(
    input  wire        rx_clk,
    input  wire        rst_n,

    input  wire [7:0]  rx_d,
    input  wire        rx_dv,
    input  wire        rx_er,
    input  wire        rx_ce,

    output reg         pause_tgl,      // flips once per valid PAUSE frame
    output reg  [15:0] pause_quanta    // pause_time of the last matched frame (see above)
);

    // =========================================================================
    // rx_clk reset synchronizer
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg rst_n_s1, rst_n_s2;
    always @(posedge rx_clk or negedge rst_n) begin
        if (!rst_n) {rst_n_s2, rst_n_s1} <= 2'b00;
        else        {rst_n_s2, rst_n_s1} <= {rst_n_s1, 1'b1};
    end

    // =========================================================================
    // Byte stage: one registered byte strobe per received byte, and a frame-
    // end strobe on the cycle after rx_dv falls, so it always follows the
    // frame's last byte strobe. b_end_er comes with b_end: the frame had
    // rx_er (see above).
    // =========================================================================
    reg  [7:0] b_d;
    reg        b_stb;
    reg        b_end;
    reg        b_end_er;
    reg        dv_d1;
    reg        dv_er;        // rx_er seen in this frame so far
    reg        nib_algn;     // RX_NIBBLE: SFD seen, nibbles now pair in twos
    reg        nib_have;     // RX_NIBBLE: nib_low holds a nibble
    reg  [3:0] nib_low;

    always @(posedge rx_clk or negedge rst_n_s2) begin
        if (!rst_n_s2) begin
            b_d      <= 8'd0;
            b_stb    <= 1'b0;
            b_end    <= 1'b0;
            b_end_er <= 1'b0;
            dv_d1    <= 1'b0;
            dv_er    <= 1'b0;
            nib_algn <= 1'b0;
            nib_have <= 1'b0;
            nib_low  <= 4'd0;
        end else begin
            dv_d1    <= rx_dv;
            b_end    <= dv_d1 && !rx_dv;
            b_end_er <= dv_er;
            dv_er    <= rx_dv && (dv_er || (rx_er && (RX_NIBBLE != 0 || rx_ce)));
            b_stb    <= 1'b0;
            // Nibble pairing (used only when RX_NIBBLE != 0). Until the SFD,
            // each nibble is paired with the one before it, so the preamble
            // reads as 0x55 bytes and the SFD (nibbles 5 then D) is found
            // after an odd or an even number of preamble nibbles. From the
            // SFD on, nibbles pair in twos.
            if (rx_dv) begin
                nib_low  <= rx_d[3:0];
                nib_have <= !(nib_algn && nib_have);
                if (!nib_algn && nib_have && nib_low == 4'h5 && rx_d[3:0] == 4'hD) begin
                    nib_algn <= 1'b1;
                    nib_have <= 1'b0;
                end
            end else begin
                nib_algn <= 1'b0;
                nib_have <= 1'b0;
            end
            if (RX_NIBBLE != 0) begin
                if (rx_dv && nib_have) begin
                    b_d   <= {rx_d[3:0], nib_low};
                    b_stb <= 1'b1;
                end
            end else if (rx_dv && rx_ce) begin
                b_d   <= rx_d;
                b_stb <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Parser FSM. Bytes after the SFD run through a CRC-32 and a length count
    // so a PAUSE frame is acted on only once its FCS has checked out, as 802.3
    // requires of a MAC Control frame.
    // =========================================================================
    localparam [3:0]
        RX_IDLE     = 4'd0,
        RX_DST      = 4'd1,
        RX_SRC      = 4'd2,
        RX_TYPE_HI  = 4'd3,
        RX_TYPE_LO  = 4'd4,
        RX_OP_HI    = 4'd5,
        RX_OP_LO    = 4'd6,
        RX_QUANTA_HI= 4'd7,
        RX_QUANTA_LO= 4'd8,
        RX_LATCH    = 4'd9,
        RX_DRAIN    = 4'd10,
        RX_PRE      = 4'd11;

    reg [3:0]  rx_state;
    reg [2:0]  rx_idx;       // 0..5 within DST/SRC fields
    reg [6:0]  rx_len;       // bytes after the SFD, saturating at 64

    // CRC over the bytes after the SFD. A frame whose FCS is good leaves the
    // register at the CRC-32 residue, as in eth_mac_rx.
    wire        rx_sfd    = b_stb && (rx_state == RX_PRE) && (b_d == 8'hD5);
    wire        rx_body   = b_stb && (rx_state != RX_IDLE) && (rx_state != RX_PRE) &&
                            (rx_state != RX_DRAIN);
    wire [31:0] rx_crc;
    wire        rx_fcs_ok = (rx_crc == 32'hDEBB20E3);

    crc32 u_rx_crc (
        .clk       (rx_clk),
        .rst_n     (rst_n_s2),
        .data_in   (b_d),
        .data_valid(rx_body),
        .crc_init  (rx_sfd),
        .crc_out   (),
        .crc_raw   (rx_crc)
    );

    // 802.3x reserved multicast address for MAC Control frames.
    // Wire-byte order: 01 80 C2 00 00 01.
    function automatic dst_byte_match;
        input [2:0] idx;
        input [7:0] b;
        begin
            case (idx)
                3'd0: dst_byte_match = (b == 8'h01);
                3'd1: dst_byte_match = (b == 8'h80);
                3'd2: dst_byte_match = (b == 8'hC2);
                3'd3: dst_byte_match = (b == 8'h00);
                3'd4: dst_byte_match = (b == 8'h00);
                3'd5: dst_byte_match = (b == 8'h01);
                default: dst_byte_match = 1'b0;
            endcase
        end
    endfunction

    always @(posedge rx_clk or negedge rst_n_s2) begin
        if (!rst_n_s2) begin
            rx_state     <= RX_IDLE;
            rx_idx       <= 3'd0;
            rx_len       <= 7'd0;
            pause_tgl    <= 1'b0;
            pause_quanta <= 16'd0;
        end else begin
            if (rx_body && rx_len != 7'd64)
                rx_len <= rx_len + 7'd1;

            if (b_stb) begin
                case (rx_state)
                    RX_IDLE:
                        rx_state <= (b_d == 8'h55) ? RX_PRE : RX_DRAIN;

                    RX_PRE: begin
                        rx_idx <= 3'd0;
                        rx_len <= 7'd0;
                        if (b_d == 8'hD5)
                            rx_state <= RX_DST;
                        else if (b_d != 8'h55)
                            rx_state <= RX_DRAIN;
                    end

                    RX_DST: begin
                        if (!dst_byte_match(rx_idx, b_d)) begin
                            rx_state <= RX_DRAIN;
                        end else if (rx_idx == 3'd5) begin
                            rx_state <= RX_SRC;
                            rx_idx   <= 3'd0;
                        end else begin
                            rx_idx <= rx_idx + 3'd1;
                        end
                    end

                    RX_SRC: begin
                        // Skip 6 source-MAC bytes
                        if (rx_idx == 3'd5) begin
                            rx_state <= RX_TYPE_HI;
                            rx_idx   <= 3'd0;
                        end else begin
                            rx_idx <= rx_idx + 3'd1;
                        end
                    end

                    RX_TYPE_HI: rx_state <= (b_d == 8'h88) ? RX_TYPE_LO : RX_DRAIN;
                    RX_TYPE_LO: rx_state <= (b_d == 8'h08) ? RX_OP_HI   : RX_DRAIN;
                    RX_OP_HI:   rx_state <= (b_d == 8'h00) ? RX_OP_LO   : RX_DRAIN;
                    RX_OP_LO:   rx_state <= (b_d == 8'h01) ? RX_QUANTA_HI : RX_DRAIN;

                    RX_QUANTA_HI: begin
                        pause_quanta[15:8] <= b_d;
                        rx_state <= RX_QUANTA_LO;
                    end
                    RX_QUANTA_LO: begin
                        pause_quanta[7:0] <= b_d;
                        rx_state <= RX_LATCH;
                    end

                    RX_LATCH, RX_DRAIN: ;  // wait for end of frame
                    default:    rx_state <= RX_IDLE;
                endcase
            end

            if (b_end) begin
                // End of frame. Commit a matched PAUSE frame only if it was a
                // valid frame.
                if (rx_state == RX_LATCH && rx_fcs_ok && !b_end_er && rx_len == 7'd64)
                    pause_tgl <= ~pause_tgl;
                rx_state <= RX_IDLE;
                rx_idx   <= 3'd0;
            end
        end
    end

endmodule
