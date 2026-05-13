// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// arp_responder.v - Minimal ARP reply engine
// Captures incoming Ethernet frames, detects ARP requests for our IP,
// and sends ARP replies. Makes the board pingable on the network.
// Verilog 2001
// =============================================================================

module arp_responder (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    // ---- RX from MAC (AXI4-Stream master) ----
    input  wire [7:0]  rx_tdata,
    input  wire        rx_tvalid,
    input  wire        rx_tlast,
    input  wire        rx_terror,
    input  wire        rx_tsof,

    // ---- TX to MAC (AXI4-Stream slave) ----
    output wire [7:0]  tx_tdata,
    output reg         tx_tvalid,
    input  wire        tx_tready,
    output wire        tx_tlast,

    // ---- Configuration ----
    input  wire [47:0] our_mac,   // e.g., 48'h020000000001
    input  wire [31:0] our_ip,    // e.g., 32'hC0A801C8 = 192.168.1.200

    // ---- Status ----
    output reg         arp_reply_sent
);

    // Capture first 42 bytes of each frame:
    // [0:5]   dst MAC
    // [6:11]  src MAC
    // [12:13] EtherType
    // [14:41] ARP payload (28 bytes)
    reg [7:0]  cap [0:41];
    reg [5:0]  cap_idx;
    reg        capturing;
    reg        frame_valid;

    // TX state
    reg [7:0]  reply [0:41];
    reg [5:0]  tx_idx;

    localparam [2:0]
        RX_IDLE  = 3'd0,
        RX_CAP   = 3'd1,
        RX_SKIP  = 3'd2,
        TX_SEND  = 3'd3,
        TX_WAIT  = 3'd4;

    reg [2:0] state;

    // Drive tx_tdata and tx_tlast combinationally from the current index.
    // A registered tx_tdata <= reply[tx_idx] would lag tx_idx by one cycle
    // (reply[0] sent twice, reply[41] dropped); a registered tx_tlast was
    // also clobbered to 0 in the same cycle the inner if-clause fired.
    assign tx_tdata = reply[tx_idx];
    assign tx_tlast = tx_tvalid && (tx_idx == 6'd41);

    // Check if captured frame is an ARP request for our IP
    wire is_arp_request =
        (cap[12] == 8'h08) && (cap[13] == 8'h06) &&  // EtherType = ARP
        (cap[20] == 8'h00) && (cap[21] == 8'h01) &&  // Opcode = request
        (cap[38] == our_ip[31:24]) && (cap[39] == our_ip[23:16]) &&
        (cap[40] == our_ip[15:8])  && (cap[41] == our_ip[7:0]);   // Target IP = ours

    integer ri;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= RX_IDLE;
            cap_idx        <= 6'd0;
            capturing      <= 1'b0;
            frame_valid    <= 1'b0;
            tx_tvalid      <= 1'b0;
            tx_idx         <= 6'd0;
            arp_reply_sent <= 1'b0;
            for (ri = 0; ri < 42; ri = ri + 1) begin
                cap[ri]   <= 8'd0;
                reply[ri] <= 8'd0;
            end
        end else begin
            case (state)
                RX_IDLE: begin
                    tx_tvalid <= 1'b0;
                    if (enable && rx_tvalid && rx_tsof) begin
                        cap[0]  <= rx_tdata;
                        cap_idx <= 6'd1;
                        state   <= RX_CAP;
                    end
                end

                RX_CAP: begin
                    if (rx_tvalid) begin
                        if (cap_idx < 6'd42)
                            cap[cap_idx] <= rx_tdata;
                        cap_idx <= cap_idx + 6'd1;

                        if (rx_tlast) begin
                            if (!rx_terror && cap_idx >= 6'd41) begin
                                // Frame complete, check if ARP request
                                state <= TX_WAIT;
                            end else begin
                                state <= RX_IDLE;
                            end
                        end
                    end
                end

                TX_WAIT: begin
                    // One-cycle delay to let is_arp_request evaluate
                    if (is_arp_request) begin
                        // Build ARP reply in reply buffer
                        // Dst MAC = sender MAC from request
                        reply[0]  <= cap[22]; reply[1]  <= cap[23];
                        reply[2]  <= cap[24]; reply[3]  <= cap[25];
                        reply[4]  <= cap[26]; reply[5]  <= cap[27];
                        // Src MAC = our MAC
                        reply[6]  <= our_mac[47:40]; reply[7]  <= our_mac[39:32];
                        reply[8]  <= our_mac[31:24]; reply[9]  <= our_mac[23:16];
                        reply[10] <= our_mac[15:8];  reply[11] <= our_mac[7:0];
                        // EtherType = ARP
                        reply[12] <= 8'h08; reply[13] <= 8'h06;
                        // ARP header (same as request)
                        reply[14] <= 8'h00; reply[15] <= 8'h01; // HTYPE
                        reply[16] <= 8'h08; reply[17] <= 8'h00; // PTYPE
                        reply[18] <= 8'h06; reply[19] <= 8'h04; // HLEN, PLEN
                        // Opcode = 2 (reply)
                        reply[20] <= 8'h00; reply[21] <= 8'h02;
                        // Sender MAC = our MAC
                        reply[22] <= our_mac[47:40]; reply[23] <= our_mac[39:32];
                        reply[24] <= our_mac[31:24]; reply[25] <= our_mac[23:16];
                        reply[26] <= our_mac[15:8];  reply[27] <= our_mac[7:0];
                        // Sender IP = our IP
                        reply[28] <= our_ip[31:24]; reply[29] <= our_ip[23:16];
                        reply[30] <= our_ip[15:8];  reply[31] <= our_ip[7:0];
                        // Target MAC = sender MAC from request
                        reply[32] <= cap[22]; reply[33] <= cap[23];
                        reply[34] <= cap[24]; reply[35] <= cap[25];
                        reply[36] <= cap[26]; reply[37] <= cap[27];
                        // Target IP = sender IP from request
                        reply[38] <= cap[28]; reply[39] <= cap[29];
                        reply[40] <= cap[30]; reply[41] <= cap[31];

                        tx_idx <= 6'd0;
                        state  <= TX_SEND;
                    end else begin
                        state <= RX_IDLE;
                    end
                end

                TX_SEND: begin
                    tx_tvalid <= 1'b1;
                    if (tx_tready && tx_tvalid) begin
                        if (tx_idx == 6'd41) begin
                            tx_tvalid      <= 1'b0;
                            arp_reply_sent <= 1'b1;
                            state          <= RX_IDLE;
                        end else begin
                            tx_idx <= tx_idx + 6'd1;
                        end
                    end
                end

                default: state <= RX_IDLE;
            endcase

            // Drain RX if we're not capturing (don't block MAC)
            if (state == RX_IDLE && rx_tvalid && !rx_tsof) begin
                // skip
            end
        end
    end

endmodule
