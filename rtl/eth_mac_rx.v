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
    parameter AXIS_FIFO_ADDR_WIDTH = 8,    // 256 bytes (BRAM-backed sync FIFO)
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
    output reg         stat_err_oversize,// length > MAX_FRAME (std/jumbo gated)
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
    reg        rx_er_seen;
    reg        rx_overflow_seen;
    reg        is_bcast_r;
    reg        is_mcast_r;

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
                          mac_chk[0] &&
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

    wire        fifo_full;
    wire        fifo_overflow;
    wire [10:0] fifo_rd_data;
    wire        fifo_rd_valid;

    sync_fifo #(
        .DATA_WIDTH (11),
        .ADDR_WIDTH (AXIS_FIFO_ADDR_WIDTH)
    ) u_fifo (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_data     ({push_sof, push_err, push_last, push_data}),
        .wr_en       (push_en),
        .wr_full     (fifo_full),
        .rd_data     (fifo_rd_data),
        .rd_valid    (fifo_rd_valid),
        .rd_en       (m_axis_tready),
        .rd_empty    (),
        .count       (),
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
    wire err_oversize_now = (!jumbo_en && (byte_cnt > MAX_FRAME_STD)) ||
                            (jumbo_en  && (byte_cnt > MAX_FRAME_JUMBO));

    // Combinational push request from the receive FSM. Lifted out of the FSM
    // always block so it drives sync_fifo.wr_en cleanly on the same posedge.
    always @* begin
        push_en   = 1'b0;
        push_data = 8'd0;
        push_last = 1'b0;
        push_err  = 1'b0;
        push_sof  = 1'b0;
        case (state)
            S_DATA: begin
                if (gmii_rx_dv && (
                        (byte_cnt == 14'd5 && mac_pass_now) ||
                        (byte_cnt >= 14'd6 && mac_ok))) begin
                    push_en   = 1'b1;
                    push_data = delay_pipe1;
                    push_sof  = (byte_cnt == 14'd5);
                end
            end
            S_CRC_CHECK: begin
                if (byte_cnt >= 14'd6 && mac_ok) begin
                    push_en   = 1'b1;
                    push_data = delay_pipe1;
                    push_last = 1'b1;
                    push_err  = err_fcs_now || err_align_now ||
                                err_overflow_now || err_oversize_now;
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
            rx_er_seen       <= 1'b0;
            rx_overflow_seen <= 1'b0;
            is_bcast_r       <= 1'b0;
            is_mcast_r       <= 1'b0;
            stat_done         <= 1'b0;
            stat_len          <= 14'd0;
            stat_err_fcs      <= 1'b0;
            stat_err_align    <= 1'b0;
            stat_err_overflow <= 1'b0;
            stat_err_oversize <= 1'b0;
            stat_is_bcast     <= 1'b0;
            stat_is_mcast     <= 1'b0;
        end else begin
            crc_init         <= 1'b0;
            crc_data_valid   <= 1'b0;
            stat_done         <= 1'b0;

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
                    rx_er_seen       <= 1'b0;
                    rx_overflow_seen <= 1'b0;
                    is_bcast_r       <= 1'b0;
                    is_mcast_r       <= 1'b0;
                    if (gmii_rx_dv && gmii_rxd == 8'h55)
                        state <= S_PREAMBLE;
                end

                S_PREAMBLE: begin
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
                                 mac_chk[0] &&
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

                        delay_pipe5 <= gmii_rxd;
                        delay_pipe4 <= delay_pipe5;
                        delay_pipe3 <= delay_pipe4;
                        delay_pipe2 <= delay_pipe3;
                        delay_pipe1 <= delay_pipe2;
                        delay_pipe0 <= delay_pipe1;

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
                    if (mac_ok) begin
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

            // Sticky overflow flag, latched on any dropped FIFO write.
            if (fifo_overflow)
                rx_overflow_seen <= 1'b1;
        end
    end

endmodule
