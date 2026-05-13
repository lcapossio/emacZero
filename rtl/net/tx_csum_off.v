// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tx_csum_off.v - IPv4 / UDP TX checksum offload (inline AXIS pass-through)
// Verilog 2001
// =============================================================================
// Sits inline on the AXI4-Stream byte path between the network stack and
// the MAC TX. When `enable` is high and the frame is a valid Ethernet/IPv4
// frame, this module:
//   - Computes the IP header checksum across bytes [14:33] (assuming IHL=5)
//     and overwrites bytes [24:25].
//   - Clears the UDP checksum field at bytes [40:41] when protocol == 17.
// When `enable` is low or the frame doesn't match, bytes pass through with
// only a fixed pipeline delay (one frame's worth of buffering).
//
// Limits:
//   - Only IPv4 with IHL=5 (no options) is patched.
//   - Up to MAX_FRAME bytes per frame; over-length frames pass through
//     untouched (no checksum patch).
//   - UDP checksum is set to zero rather than computed; that is legal under
//     IPv4 (RFC 768 §3) and avoids a second pseudo-header pass.
// =============================================================================

module tx_csum_off #(
    parameter MAX_FRAME = 9018
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
    output reg  [7:0]  m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast
);

    // Frame buffer
    localparam ADDR_W = $clog2(MAX_FRAME);
    reg [7:0]  buf_mem [0:MAX_FRAME-1];
    reg [ADDR_W-1:0] wr_ptr;
    reg [ADDR_W-1:0] rd_ptr;
    reg [ADDR_W-1:0] frame_len;
    reg              frame_complete;
    reg              frame_too_big;

    // Parsed header fields
    reg [15:0] eth_type;       // bytes 12-13
    reg [3:0]  ip_ihl;         // byte 14, lower nibble
    reg [7:0]  ip_protocol;    // byte 23

    // IP checksum accumulator
    reg [31:0] ip_csum_acc;
    reg [7:0]  csum_tmp_byte;
    reg        csum_tmp_have;

    // Computed checksum
    wire [16:0] csum_fold1 = ip_csum_acc[15:0] + ip_csum_acc[31:16];
    wire [15:0] csum_fold2 = csum_fold1[15:0] + {15'd0, csum_fold1[16]};
    wire [15:0] ip_checksum = ~csum_fold2;

    // Per-byte rewrite table
    wire is_ipv4    = (eth_type == 16'h0800) && (ip_ihl == 4'd5);
    wire is_udp     = is_ipv4 && (ip_protocol == 8'd17);
    wire patch_csum = enable && is_ipv4 && !frame_too_big;

    // =========================================================================
    // INGEST: capture every byte, parse headers, accumulate IP checksum
    // =========================================================================
    assign s_axis_tready = !frame_complete;

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr         <= {ADDR_W{1'b0}};
            frame_len      <= {ADDR_W{1'b0}};
            frame_complete <= 1'b0;
            frame_too_big  <= 1'b0;
            eth_type       <= 16'd0;
            ip_ihl         <= 4'd0;
            ip_protocol    <= 8'd0;
            ip_csum_acc    <= 32'd0;
            csum_tmp_byte  <= 8'd0;
            csum_tmp_have  <= 1'b0;
        end else begin
            if (s_axis_tvalid && s_axis_tready) begin
                if (wr_ptr < MAX_FRAME-1) begin
                    buf_mem[wr_ptr] <= s_axis_tdata;
                    wr_ptr          <= wr_ptr + 1'b1;
                end else begin
                    frame_too_big <= 1'b1;
                end

                // Parse Ethernet type / IP header fields
                case (wr_ptr)
                    14'd12: eth_type[15:8] <= s_axis_tdata;
                    14'd13: eth_type[7:0]  <= s_axis_tdata;
                    14'd14: ip_ihl         <= s_axis_tdata[3:0];
                    14'd23: ip_protocol    <= s_axis_tdata;
                    default: ;
                endcase

                // Accumulate IP header checksum across bytes 14..33 (20-byte
                // IPv4 header). Skip bytes 24,25 (the checksum field itself).
                // We assume IHL=5; if it's larger we still produce a result
                // but the caller has already filtered on is_ipv4.
                if ((wr_ptr >= 14'd14) && (wr_ptr <= 14'd33) &&
                    (wr_ptr != 14'd24) && (wr_ptr != 14'd25)) begin
                    if (!csum_tmp_have) begin
                        csum_tmp_byte <= s_axis_tdata;
                        csum_tmp_have <= 1'b1;
                    end else begin
                        ip_csum_acc <= ip_csum_acc +
                                       {16'd0, csum_tmp_byte, s_axis_tdata};
                        csum_tmp_have <= 1'b0;
                    end
                end

                if (s_axis_tlast) begin
                    frame_len      <= wr_ptr + 1'b1;
                    frame_complete <= 1'b1;
                end
            end

            // Drained -> reset for next frame.
            // Fires uniquely on the last AXIS handshake of the egress.
            if (frame_complete && m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
                wr_ptr         <= {ADDR_W{1'b0}};
                frame_len      <= {ADDR_W{1'b0}};
                frame_complete <= 1'b0;
                frame_too_big  <= 1'b0;
                ip_csum_acc    <= 32'd0;
                csum_tmp_byte  <= 8'd0;
                csum_tmp_have  <= 1'b0;
            end
        end
    end

    // =========================================================================
    // EGRESS: stream out, patching checksum bytes
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            rd_ptr        <= {ADDR_W{1'b0}};
            m_axis_tdata  <= 8'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else begin
            if (frame_complete) begin
                if (!m_axis_tvalid || m_axis_tready) begin
                    if (rd_ptr < frame_len) begin
                        // Default: pass through
                        m_axis_tdata  <= buf_mem[rd_ptr];
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast  <= (rd_ptr == frame_len - 1);

                        // Patch IP header checksum (bytes 24,25)
                        if (patch_csum && rd_ptr == {{ADDR_W-5{1'b0}}, 5'd24})
                            m_axis_tdata <= ip_checksum[15:8];
                        else if (patch_csum && rd_ptr == {{ADDR_W-5{1'b0}}, 5'd25})
                            m_axis_tdata <= ip_checksum[7:0];

                        // Zero UDP checksum (bytes 40,41 — IP+UDP header)
                        if (patch_csum && is_udp && rd_ptr == {{ADDR_W-6{1'b0}}, 6'd40})
                            m_axis_tdata <= 8'd0;
                        else if (patch_csum && is_udp && rd_ptr == {{ADDR_W-6{1'b0}}, 6'd41})
                            m_axis_tdata <= 8'd0;

                        rd_ptr <= rd_ptr + 1'b1;
                    end else begin
                        m_axis_tvalid <= 1'b0;
                        m_axis_tlast  <= 1'b0;
                    end
                end

                if (m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
                    rd_ptr        <= {ADDR_W{1'b0}};
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                end
            end else begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
                rd_ptr        <= {ADDR_W{1'b0}};
            end
        end
    end

endmodule
