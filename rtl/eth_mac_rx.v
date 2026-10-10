// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_mac_rx.v - Ethernet MAC Receive Path
// Strips preamble/SFD, validates CRC, filters destination MAC, and exposes a
// byte-wide AXI4-Stream output with internal buffering for downstream stalls.
// Verilog 2001
// =============================================================================

module eth_mac_rx #(
    parameter MCAST_HASH_FILTER   = 0,
    // The PHY cannot be backpressured. Keep enough RX buffering for typical
    // downstream DMA stalls before declaring an overflow error; the system
    // wrapper's error-drop stage provides the full-frame correctness boundary.
    parameter AXIS_FIFO_ADDR_WIDTH = 11,   // 2048 bytes (BRAM-backed sync FIFO)
    // Frame-size limits in wire bytes after the SFD, FCS included. A frame
    // with an 802.1Q / 802.1ad tag may be 4 bytes over MAX_FRAME_STD (1522),
    // as 802.3 allows. jumbo_en raises the limit to MAX_FRAME_JUMBO, tagged
    // or not, and never lowers it below the standard one.
    parameter MAX_FRAME_STD       = 1518,  // 802.3 standard
    parameter MAX_FRAME_JUMBO     = 9018   // typical jumbo MTU + headers
)(
    input  wire        clk,
    input  wire        rst_n,

    // GMII RX interface (from RGMII or direct PHY)
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_dv,
    input  wire        gmii_rx_er,

    // MAC address filter
    input  wire [47:0] our_mac,
    input  wire        promisc,
    input  wire        passthrough,      // sniffer mode: also bypass MAC filter
                                         // and never drop on FCS/size errors;
                                         // m_axis_terror still flagged.

    // Frame-size policy
    input  wire        jumbo_en,         // 1 = accept up to MAX_FRAME_JUMBO

    // Multicast hash table (64 bits). Ignored when MCAST_HASH_FILTER == 0.
    input  wire [63:0] mcast_hash_table,

    // AXI4-Stream master frame data output. Preamble/SFD/FCS are removed.
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_terror,
    output wire        m_axis_tsof,

    // Per-frame classification pulses (single-cycle, end-of-frame)
    output reg         stat_done,        // pulses 1 cycle when a frame ends
    output reg  [13:0] stat_len,         // total wire bytes including FCS
    output reg         stat_err_fcs,
    output reg         stat_err_align,   // rx_er asserted during frame
    output reg         stat_err_overflow,// FIFO overflow during frame
    output reg         stat_err_oversize,// length > MAX_FRAME (std/jumbo gated,
                                         // std +4 for a VLAN-tagged frame)
    output reg         stat_is_bcast,    // dst-MAC = FF:FF:FF:FF:FF:FF
    output reg         stat_is_mcast     // dst-MAC[byte0][LSB]=1 and !bcast
);

    localparam [2:0]
        S_IDLE      = 3'd0,
        S_PREAMBLE  = 3'd1,
        S_DATA      = 3'd2,
        S_DROP      = 3'd3,
        S_CRC_CHECK = 3'd4;

    localparam AXIS_FIFO_DEPTH = (1 << AXIS_FIFO_ADDR_WIDTH);

    reg [2:0]  state;
    reg [13:0] byte_cnt;
    reg        first_byte;

    wire [31:0] crc_out;
    reg         crc_init;
    reg         crc_data_valid;
    reg  [7:0]  crc_data_in;

    // Delay six bytes so the four-byte FCS is stripped and the destination
    // address decision is known before the first output byte is queued.
    reg [7:0] delay_pipe0;
    reg [7:0] delay_pipe1;
    reg [7:0] delay_pipe2;
    reg [7:0] delay_pipe3;
    reg [7:0] delay_pipe4;
    reg [7:0] delay_pipe5;

    reg [47:0] dst_mac_captured;
    reg        mac_ok;
    reg        frame_started;    // this frame's SOF word made it into the FIFO
    reg        rx_er_seen;
    reg        rx_overflow_seen;
    reg        is_bcast_r;
    reg        is_mcast_r;
    reg        vlan_tag;         // bytes 12-13 are TPID 0x8100 or 0x88A8

    wire [47:0] mac_chk = {dst_mac_captured[39:0], gmii_rxd};
    wire [5:0]  mcast_hash_idx = mac_chk[5:0]   ^ mac_chk[11:6]  ^
                                  mac_chk[17:12] ^ mac_chk[23:18] ^
                                  mac_chk[29:24] ^ mac_chk[35:30] ^
                                  mac_chk[41:36] ^ mac_chk[47:42];

    // Combinational MAC-pass at byte_cnt=5. Used to gate the byte_cnt=5 push
    // since mac_ok is registered (lands one cycle later, after byte 0 has
    // already shifted past delay_pipe1).
    wire mac_pass_now = (mac_chk == our_mac) ||
                         (mac_chk == 48'hFFFFFFFFFFFF) ||
                         promisc || passthrough ||
                         (MCAST_HASH_FILTER &&
                          mac_chk[40] &&
                          mac_chk != 48'hFFFFFFFFFFFF &&
                          mcast_hash_table[mcast_hash_idx]);

    // Output FIFO (BRAM, sync, FWFT). One word per byte, packed so all the
    // metadata flags ride alongside data into a single BRAM column.
    //   bit 10: sof, bit 9: err, bit 8: last, bits 7:0: data
    reg       push_en;
    reg [7:0] push_data;
    reg       push_last;
    reg       push_err;
    reg       push_sof;
    reg       data_drop;        // a data byte was dropped for want of FIFO room
    reg       push_en_r;
    reg [7:0] push_data_r;
    reg       push_last_r;
    reg       push_err_r;
    reg       push_sof_r;

    wire        fifo_full;
    wire        fifo_overflow;
    wire [10:0] fifo_rd_data;
    wire        fifo_rd_valid;
    wire [AXIS_FIFO_ADDR_WIDTH:0] fifo_count;

    // Reserve a few slots so a frame's SOF and closing TLAST words are never the
    // ones dropped on overflow: once occupancy passes the high-water mark we stop
    // pushing DATA (dropped bytes just set the overflow/terror flag), but the SOF
    // that starts a frame and the TLAST that ends it always find room. That keeps
    // AXIS framing intact under backpressure - a dropped SOF would leave the sink
    // unable to delimit, and a dropped TLAST would merge this frame into the next.
    localparam [AXIS_FIFO_ADDR_WIDTH:0] FIFO_HWM = AXIS_FIFO_DEPTH - 4;
    wire fifo_room = (fifo_count < FIFO_HWM);

    sync_fifo #(
        .DATA_WIDTH (11),
        .ADDR_WIDTH (AXIS_FIFO_ADDR_WIDTH)
    ) u_fifo (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_data     ({push_sof_r, push_err_r, push_last_r, push_data_r}),
        .wr_en       (push_en_r),
        .wr_full     (fifo_full),
        .rd_data     (fifo_rd_data),
        .rd_valid    (fifo_rd_valid),
        .rd_en       (m_axis_tready),
        .rd_empty    (),
        .count       (fifo_count),
        .wr_overflow (fifo_overflow)
    );

    assign m_axis_tdata  = fifo_rd_data[7:0];
    assign m_axis_tlast  = fifo_rd_data[8];
    assign m_axis_terror = fifo_rd_data[9];
    assign m_axis_tsof   = fifo_rd_data[10];
    assign m_axis_tvalid = fifo_rd_valid;

    crc32 u_crc (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (crc_data_in),
        .data_valid(crc_data_valid),
        .crc_init  (crc_init),
        .crc_out   (),
        .crc_raw   (crc_out)
    );

    // Per-error breakdown: classify the four error sources individually so
    // eth_stats can update separate counters in addition to the AXIS terror.
    wire err_fcs_now      = (crc_out != 32'hDEBB20E3);
    wire err_align_now    = rx_er_seen;
    wire err_overflow_now = rx_overflow_seen;
    wire over_std_now     = vlan_tag ? (byte_cnt > MAX_FRAME_STD + 4)
                                     : (byte_cnt > MAX_FRAME_STD);
    wire err_oversize_now = over_std_now &&
                            (!jumbo_en || (byte_cnt > MAX_FRAME_JUMBO));

    // byte_cnt saturates at 16383, so a limit of 16383 or more could never be
    // exceeded and oversize frames would pass clean. Verilog-2001 has no
    // elaboration-time $error, so an unsupported limit instantiates a module
    // that does not exist; its name is the error message.
    generate
        if ((MAX_FRAME_JUMBO > 16382) || (MAX_FRAME_STD + 4 > 16382)) begin : gen_limit_check
            EMACZERO_CONFIG_ERROR_eth_mac_rx_frame_limit_must_be_at_most_16382
                u_frame_limit_too_large ();
        end
    endgenerate
    // Runt: a valid 802.3 frame is >= 64 wire bytes (60 data/pad + 4 FCS).
    // byte_cnt counts bytes after the SFD, so < 64 is undersized - a collision
    // fragment or truncated frame. Deliver it with terror instead of as a clean
    // frame with a garbage FCS, so the wrapper's error-drop stage discards it.
    wire err_undersize_now = (byte_cnt < 14'd64);

    // Combinational push request from the receive FSM. This is registered
    // before sync_fifo so MAC filtering does not directly drive the FIFO CE
    // fanout in the same 100 MHz cycle.
    always @* begin
        push_en   = 1'b0;
        push_data = 8'd0;
        push_last = 1'b0;
        push_err  = 1'b0;
        push_sof  = 1'b0;
        data_drop = 1'b0;
        case (state)
            S_DATA: begin
                if (gmii_rx_dv && byte_cnt == 14'd5 && mac_pass_now) begin
                    // SOF: start the frame only if it can be buffered. If not,
                    // frame_started stays 0 and the whole frame is cleanly
                    // dropped (no partial, so the sink's delimiting is unharmed).
                    if (fifo_room) begin
                        push_en   = 1'b1;
                        push_data = delay_pipe1;
                        push_sof  = 1'b1;
                    end
                end else if (gmii_rx_dv && byte_cnt >= 14'd6 &&
                             mac_ok && frame_started) begin
                    // Data byte: push while there is headroom; otherwise drop it
                    // and flag overflow so the frame is terror'd (its reserved
                    // SOF/TLAST still bound it correctly).
                    if (fifo_room) begin
                        push_en   = 1'b1;
                        push_data = delay_pipe1;
                    end else begin
                        data_drop = 1'b1;
                    end
                end
            end
            S_CRC_CHECK: begin
                // Always emit the closing word for a started frame - the reserved
                // headroom guarantees room, so the frame is always terminated.
                if (byte_cnt >= 14'd6 && mac_ok && frame_started) begin
                    push_en   = 1'b1;
                    push_data = delay_pipe1;
                    push_last = 1'b1;
                    push_err  = err_fcs_now || err_align_now ||
                                err_overflow_now || err_oversize_now ||
                                err_undersize_now;
                end
            end
            default: ;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            byte_cnt         <= 14'd0;
            first_byte       <= 1'b0;
            crc_init         <= 1'b0;
            crc_data_valid   <= 1'b0;
            crc_data_in      <= 8'd0;
            delay_pipe0      <= 8'd0;
            delay_pipe1      <= 8'd0;
            delay_pipe2      <= 8'd0;
            delay_pipe3      <= 8'd0;
            delay_pipe4      <= 8'd0;
            delay_pipe5      <= 8'd0;
            dst_mac_captured <= 48'd0;
            mac_ok           <= 1'b0;
            frame_started    <= 1'b0;
            rx_er_seen       <= 1'b0;
            rx_overflow_seen <= 1'b0;
            is_bcast_r       <= 1'b0;
            is_mcast_r       <= 1'b0;
            vlan_tag         <= 1'b0;
            stat_done         <= 1'b0;
            stat_len          <= 14'd0;
            stat_err_fcs      <= 1'b0;
            stat_err_align    <= 1'b0;
            stat_err_overflow <= 1'b0;
            stat_err_oversize <= 1'b0;
            stat_is_bcast     <= 1'b0;
            stat_is_mcast     <= 1'b0;
            push_en_r         <= 1'b0;
            push_data_r       <= 8'd0;
            push_last_r       <= 1'b0;
            push_err_r        <= 1'b0;
            push_sof_r        <= 1'b0;
        end else begin
            crc_init         <= 1'b0;
            crc_data_valid   <= 1'b0;
            stat_done         <= 1'b0;
            push_en_r         <= push_en;
            push_data_r       <= push_data;
            push_last_r       <= push_last;
            push_err_r        <= push_err;
            push_sof_r        <= push_sof;

            // The frame is "started" once its SOF word is committed to the FIFO;
            // gates data/TLAST pushes and stat_done so a frame whose SOF could not
            // be buffered is dropped whole (no partial, no phantom stat).
            if (push_sof)
                frame_started <= 1'b1;

            case (state)
                S_IDLE: begin
                    byte_cnt         <= 14'd0;
                    first_byte       <= 1'b0;
                    delay_pipe0      <= 8'd0;
                    delay_pipe1      <= 8'd0;
                    delay_pipe2      <= 8'd0;
                    delay_pipe3      <= 8'd0;
                    delay_pipe4      <= 8'd0;
                    delay_pipe5      <= 8'd0;
                    dst_mac_captured <= 48'd0;
                    mac_ok           <= 1'b0;
                    frame_started    <= 1'b0;
                    rx_er_seen       <= 1'b0;
                    rx_overflow_seen <= 1'b0;
                    is_bcast_r       <= 1'b0;
                    is_mcast_r       <= 1'b0;
                    vlan_tag         <= 1'b0;
                    if (gmii_rx_dv && gmii_rxd == 8'h55)
                        state <= S_PREAMBLE;
                end

                S_PREAMBLE: begin
                    // A carrier/coding error on a preamble or SFD byte is a valid
                    // 802.3 error indication; latch it so the frame is delivered
                    // with terror + stat_err_align, not silently clean.
                    if (gmii_rx_er)
                        rx_er_seen <= 1'b1;
                    if (!gmii_rx_dv) begin
                        state <= S_IDLE;
                    end else if (gmii_rxd == 8'hD5) begin
                        state      <= S_DATA;
                        first_byte <= 1'b1;
                        crc_init   <= 1'b1;
                    end else if (gmii_rxd != 8'h55) begin
                        state <= S_DROP;
                    end
                end

                S_DATA: begin
                    if (gmii_rx_er)
                        rx_er_seen <= 1'b1;

                    if (!gmii_rx_dv) begin
                        state <= S_CRC_CHECK;
                    end else begin
                        crc_data_valid <= 1'b1;
                        crc_data_in    <= gmii_rxd;

                        if (byte_cnt < 14'd6)
                            dst_mac_captured <= {dst_mac_captured[39:0], gmii_rxd};

                        if (byte_cnt == 14'd5) begin
                            if (mac_chk == our_mac ||
                                mac_chk == 48'hFFFFFFFFFFFF ||
                                promisc || passthrough ||
                                (MCAST_HASH_FILTER &&
                                 mac_chk[40] &&
                                 mac_chk != 48'hFFFFFFFFFFFF &&
                                 mcast_hash_table[mcast_hash_idx]))
                                mac_ok <= 1'b1;
                            else
                                mac_ok <= 1'b0;

                            // Bcast / mcast classification on dst-MAC byte 0 LSB.
                            // mac_chk[40] = first dst-MAC byte's LSB (I/G bit).
                            is_bcast_r <= (mac_chk == 48'hFFFFFFFFFFFF);
                            is_mcast_r <= mac_chk[40] &&
                                          (mac_chk != 48'hFFFFFFFFFFFF);
                        end

                        // delay_pipe5 still holds byte 12 here.
                        if (byte_cnt == 14'd13)
                            vlan_tag <= ({delay_pipe5, gmii_rxd} == 16'h8100) ||
                                        ({delay_pipe5, gmii_rxd} == 16'h88A8);

                        delay_pipe5 <= gmii_rxd;
                        delay_pipe4 <= delay_pipe5;
                        delay_pipe3 <= delay_pipe4;
                        delay_pipe2 <= delay_pipe3;
                        delay_pipe1 <= delay_pipe2;
                        delay_pipe0 <= delay_pipe1;

                        // Saturate instead of wrapping. byte_cnt gates dst
                        // capture (<6), the MAC decision (==5) and oversize
                        // (>MAX_FRAME); a 14-bit wrap at 16384 would re-enter
                        // byte_cnt==5 mid-frame, re-capturing the dst and firing a
                        // second SOF. Freezing at 0x3FFF keeps oversize asserted
                        // (>= jumbo) and cannot re-trigger those decisions.
                        if (byte_cnt != 14'h3FFF)
                            byte_cnt <= byte_cnt + 14'd1;
                        if (first_byte)
                            first_byte <= 1'b0;
                    end
                end

                S_CRC_CHECK: begin
                    state <= S_IDLE;
                    // End-of-frame classification pulse for stats.
                    // Only emit when MAC filter passed (i.e. frame was actually
                    // delivered to the AXIS sink), so counts match deliveries.
                    if (mac_ok && frame_started) begin
                        stat_done         <= 1'b1;
                        stat_len          <= byte_cnt;
                        stat_err_fcs      <= err_fcs_now;
                        stat_err_align    <= err_align_now;
                        stat_err_overflow <= err_overflow_now;
                        stat_err_oversize <= err_oversize_now;
                        stat_is_bcast     <= is_bcast_r;
                        stat_is_mcast     <= is_mcast_r;
                    end
                end

                S_DROP: begin
                    if (!gmii_rx_dv)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase

            // Sticky overflow flag: latched on a data byte dropped for want of
            // headroom (the normal path now - SOF/TLAST are reserved), or on any
            // raw FIFO overflow as a backstop.
            if (data_drop || fifo_overflow)
                rx_overflow_seen <= 1'b1;
        end
    end

endmodule
