// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// test_sequencer.v - Hardware test FSM for emacZero on Arty A7
// Drives AXI4-Lite CSR reads/writes, MDIO commands, sends a gratuitous ARP,
// and reports results over UART.
// Verilog 2001
// =============================================================================

module test_sequencer #(
    parameter CLK_FREQ = 100_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        phy_rst_done,   // PHY reset sequence complete

    // ---- AXI4-Lite master ----
    output reg  [7:0]  m_axi_awaddr,
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,
    output reg  [31:0] m_axi_wdata,
    output reg  [3:0]  m_axi_wstrb,
    output reg         m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire        m_axi_bvalid,
    output reg         m_axi_bready,
    output reg  [7:0]  m_axi_araddr,
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire        m_axi_rvalid,
    output reg         m_axi_rready,

    // ---- AXI4-Stream TX (for gratuitous ARP) ----
    output reg  [7:0]  tx_tdata,
    output reg         tx_tvalid,
    input  wire        tx_tready,
    output reg         tx_tlast,

    // ---- UART TX ----
    output reg  [7:0]  uart_data,
    output reg         uart_valid,
    input  wire        uart_busy,

    // ---- Status outputs ----
    output reg         link_up,
    output reg         phy_id_ok,
    output reg         tx_done,
    output reg         rx_done,
    output reg         arp_tx_active  // high while sequencer owns TX bus
);

    // =========================================================================
    // CSR register offsets
    // =========================================================================
    localparam [7:0] A_VERSION    = 8'h00;
    localparam [7:0] A_CTRL       = 8'h04;
    localparam [7:0] A_STATUS     = 8'h08;
    localparam [7:0] A_MDIO_CMD   = 8'h14;
    localparam [7:0] A_MDIO_WDATA = 8'h18;
    localparam [7:0] A_MDIO_RDATA = 8'h1C;
    localparam [7:0] A_TX_FRAME   = 8'h28;
    localparam [7:0] A_RX_FRAME   = 8'h30;
    localparam [7:0] A_RX_BYTE    = 8'h34;
    localparam [7:0] A_RX_ERR     = 8'h38;
    localparam [7:0] A_SCRATCH    = 8'h3C;
    localparam [7:0] A_RX_OVERFLOW = 8'h50;

    // MDIO command encoding: [11] go, [10] write, [9:5] phy, [4:0] reg
    // PHY addr = 1 for DP83848 on Arty
    localparam [11:0] MDIO_RD_PHYIDR1 = {1'b1, 1'b0, 5'd1, 5'd2};  // reg 2
    localparam [11:0] MDIO_RD_PHYIDR2 = {1'b1, 1'b0, 5'd1, 5'd3};  // reg 3
    localparam [11:0] MDIO_RD_BMSR    = {1'b1, 1'b0, 5'd1, 5'd1};  // reg 1
    // BMCR (reg 0): enable/restart auto-negotiation. The DP83848 default
    // advertisement includes 100BASE-TX full-duplex, which avoids host-side
    // parallel-detect falling back to half-duplex.
    localparam [11:0] MDIO_WR_BMCR    = {1'b1, 1'b1, 5'd1, 5'd0};  // write, phy=1, reg=0
    localparam [11:0] MDIO_RD_BMCR    = {1'b1, 1'b0, 5'd1, 5'd0};  // read,  phy=1, reg=0
    localparam [15:0] BMCR_VALUE      = 16'h1200;  // auto-neg enable + restart

    // =========================================================================
    // Main FSM
    // =========================================================================
    localparam [5:0]
        S_WAIT_PHY   = 6'd0,
        S_RD_VER     = 6'd1,
        S_RD_VER_W   = 6'd2,
        S_PRINT_VER  = 6'd3,
        S_WR_SCR     = 6'd4,
        S_WR_SCR_W   = 6'd5,
        S_RD_SCR     = 6'd6,
        S_RD_SCR_W   = 6'd7,
        S_PRINT_SCR  = 6'd8,
        S_MDIO_PHY1  = 6'd9,
        S_MDIO_PHY1_W = 6'd10,
        S_MDIO_PHY1_P = 6'd11,
        S_MDIO_PHY1_R = 6'd12,
        S_MDIO_PHY1_RW = 6'd13,
        S_PRINT_PHY1 = 6'd14,
        S_MDIO_PHY2  = 6'd15,
        S_MDIO_PHY2_W = 6'd16,
        S_MDIO_PHY2_P = 6'd17,
        S_MDIO_PHY2_R = 6'd18,
        S_MDIO_PHY2_RW = 6'd19,
        S_PRINT_PHY2 = 6'd20,
        S_MDIO_BMSR  = 6'd21,
        S_MDIO_BMSR_W = 6'd22,
        S_MDIO_BMSR_P = 6'd23,
        S_MDIO_BMSR_R = 6'd24,
        S_MDIO_BMSR_RW = 6'd25,
        S_PRINT_LINK = 6'd26,
        S_EN_MAC     = 6'd27,
        S_EN_MAC_W   = 6'd28,
        S_SEND_ARP   = 6'd29,
        S_SEND_ARP_D = 6'd30,
        S_CHK_TX     = 6'd31,
        S_CHK_TX_W   = 6'd32,
        S_PRINT_TX   = 6'd33,
        S_WAIT_RX    = 6'd34,
        S_CHK_RX     = 6'd35,
        S_CHK_RX_W   = 6'd36,
        S_PRINT_RX   = 6'd37,
        S_PRINT_DONE = 6'd38,
        S_IDLE       = 6'd39,
        // BMCR write+readback test (MDIO write verification)
        S_MDIO_WR_BMCR   = 6'd40,  // write MDIO_WDATA then MDIO_CMD (write op)
        S_MDIO_WR_BMCR_W = 6'd41,  // wait AXI write done
        S_MDIO_WR_BMCR_P = 6'd42,  // poll STATUS until mdio_busy=0
        S_MDIO_WR_BMCR_R = 6'd43,  // read STATUS
        S_MDIO_RD_BMCR   = 6'd44,  // trigger BMCR readback
        S_MDIO_RD_BMCR_W = 6'd45,
        S_MDIO_RD_BMCR_P = 6'd46,
        S_MDIO_RD_BMCR_R = 6'd47,
        S_MDIO_RD_BMCR_RW = 6'd48,
        S_PRINT_BMCR     = 6'd49,
        // Periodic stats dump (after DONE): every ~1s emit RXF/RXB/RXE/OVF
        // lines for host-side throughput measurement.
        S_STAT_WAIT      = 6'd50,
        S_STAT_RD_RXF    = 6'd51,
        S_STAT_RD_RXF_W  = 6'd52,
        S_STAT_PRINT_RXF = 6'd53,
        S_STAT_RD_RXB    = 6'd54,
        S_STAT_RD_RXB_W  = 6'd55,
        S_STAT_PRINT_RXB = 6'd56,
        S_STAT_RD_RXE    = 6'd57,
        S_STAT_RD_RXE_W  = 6'd58,
        S_STAT_PRINT_RXE = 6'd59,
        S_STAT_RD_OVF    = 6'd60,
        S_STAT_RD_OVF_W  = 6'd61,
        S_STAT_PRINT_OVF = 6'd62;

    reg [5:0]  state;
    reg [31:0] rd_data_r;
    reg [15:0] phy1_id_r;   // explicit latch for PHY1 result used in phy_id_ok check
    reg [31:0] wait_cnt;
    reg [7:0]  arp_idx;

    // ARP frame: 42 bytes (Ethernet header + ARP payload)
    // Gratuitous ARP: sender = target, broadcast destination
    // MAC: 02:00:00:00:00:01, IP: 192.168.137.200 (0xC0A889C8)
    reg [7:0] arp_frame [0:41];

    integer ai;
    initial begin
        // Dst MAC: FF:FF:FF:FF:FF:FF (broadcast)
        arp_frame[0]  = 8'hFF; arp_frame[1]  = 8'hFF; arp_frame[2]  = 8'hFF;
        arp_frame[3]  = 8'hFF; arp_frame[4]  = 8'hFF; arp_frame[5]  = 8'hFF;
        // Src MAC: 02:00:00:00:00:01
        arp_frame[6]  = 8'h02; arp_frame[7]  = 8'h00; arp_frame[8]  = 8'h00;
        arp_frame[9]  = 8'h00; arp_frame[10] = 8'h00; arp_frame[11] = 8'h01;
        // EtherType: 0x0806 (ARP)
        arp_frame[12] = 8'h08; arp_frame[13] = 8'h06;
        // ARP: HTYPE=1(Ethernet), PTYPE=0x0800(IPv4), HLEN=6, PLEN=4
        arp_frame[14] = 8'h00; arp_frame[15] = 8'h01;
        arp_frame[16] = 8'h08; arp_frame[17] = 8'h00;
        arp_frame[18] = 8'h06; arp_frame[19] = 8'h04;
        // ARP opcode: 1 (request) - gratuitous: sender=target
        arp_frame[20] = 8'h00; arp_frame[21] = 8'h01;
        // Sender MAC: 02:00:00:00:00:01
        arp_frame[22] = 8'h02; arp_frame[23] = 8'h00; arp_frame[24] = 8'h00;
        arp_frame[25] = 8'h00; arp_frame[26] = 8'h00; arp_frame[27] = 8'h01;
        // Sender IP: 192.168.137.200
        arp_frame[28] = 8'hC0; arp_frame[29] = 8'hA8; arp_frame[30] = 8'h89; arp_frame[31] = 8'hC8;
        // Target MAC: 00:00:00:00:00:00
        arp_frame[32] = 8'h00; arp_frame[33] = 8'h00; arp_frame[34] = 8'h00;
        arp_frame[35] = 8'h00; arp_frame[36] = 8'h00; arp_frame[37] = 8'h00;
        // Target IP: 192.168.137.200 (gratuitous)
        arp_frame[38] = 8'hC0; arp_frame[39] = 8'hA8; arp_frame[40] = 8'h89; arp_frame[41] = 8'hC8;
    end

    // =========================================================================
    // String printing
    // =========================================================================
    reg [255:0] print_buf;
    reg [4:0]   print_len;
    reg [4:0]   print_idx;
    reg         printing;
    reg [5:0]   print_next_state;

    // Hex digit to ASCII
    function [7:0] hex_char;
        input [3:0] nib;
        begin
            hex_char = (nib < 4'd10) ? (8'h30 + {4'd0, nib}) : (8'h41 + {4'd0, nib} - 8'd10);
        end
    endfunction

    // Pack a 32-bit hex value + CRLF into print_buf (10 chars: XXXXXXXX\r\n)
    task setup_print_hex32;
        input [31:0] val;
        input [5:0]  next;
        begin
            print_buf[255:248] <= hex_char(val[31:28]);
            print_buf[247:240] <= hex_char(val[27:24]);
            print_buf[239:232] <= hex_char(val[23:20]);
            print_buf[231:224] <= hex_char(val[19:16]);
            print_buf[223:216] <= hex_char(val[15:12]);
            print_buf[215:208] <= hex_char(val[11:8]);
            print_buf[207:200] <= hex_char(val[7:4]);
            print_buf[199:192] <= hex_char(val[3:0]);
            print_buf[191:184] <= 8'h0D;
            print_buf[183:176] <= 8'h0A;
            print_len <= 5'd10;
            print_idx <= 5'd0;
            printing  <= 1'b1;
            print_next_state <= next;
        end
    endtask

    // Pack a 16-bit hex value + CRLF into print_buf (6 chars: XXXX\r\n)
    task setup_print_hex16;
        input [15:0] val;
        input [5:0] next;
        begin
            print_buf[255:248] <= hex_char(val[15:12]);
            print_buf[247:240] <= hex_char(val[11:8]);
            print_buf[239:232] <= hex_char(val[7:4]);
            print_buf[231:224] <= hex_char(val[3:0]);
            print_buf[223:216] <= 8'h0D;  // CR
            print_buf[215:208] <= 8'h0A;  // LF
            print_len <= 5'd6;
            print_idx <= 5'd0;
            printing  <= 1'b1;
            print_next_state <= next;
        end
    endtask

    // =========================================================================
    // AXI-Lite helper flags
    // =========================================================================
    wire wr_done = m_axi_bvalid;
    wire rd_done = m_axi_rvalid;

    // =========================================================================
    // MDIO poll counter (wait for busy to clear)
    // =========================================================================
    reg [15:0] mdio_poll_cnt;
    localparam MDIO_POLL_LIMIT = 16'd10000; // ~100us at 100MHz

    // =========================================================================
    // Main state machine
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_WAIT_PHY;
            m_axi_awaddr   <= 8'd0;
            m_axi_awvalid  <= 1'b0;
            m_axi_wdata    <= 32'd0;
            m_axi_wstrb    <= 4'hF;
            m_axi_wvalid   <= 1'b0;
            m_axi_bready   <= 1'b0;
            m_axi_araddr   <= 8'd0;
            m_axi_arvalid  <= 1'b0;
            m_axi_rready   <= 1'b0;
            tx_tdata       <= 8'd0;
            tx_tvalid      <= 1'b0;
            tx_tlast       <= 1'b0;
            uart_data      <= 8'd0;
            uart_valid     <= 1'b0;
            link_up        <= 1'b0;
            phy_id_ok      <= 1'b0;
            tx_done        <= 1'b0;
            rx_done        <= 1'b0;
            arp_tx_active  <= 1'b1;
            rd_data_r      <= 32'd0;
            phy1_id_r      <= 16'd0;
            wait_cnt       <= 32'd0;
            arp_idx        <= 8'd0;
            printing       <= 1'b0;
            print_buf      <= 256'd0;
            print_len      <= 5'd0;
            print_idx      <= 5'd0;
            print_next_state <= S_IDLE;
            mdio_poll_cnt  <= 16'd0;
        end else begin
            // Default deassert handshakes
            uart_valid <= 1'b0;

            // String printer
            if (printing) begin
                if (!uart_busy && !uart_valid) begin
                    uart_data  <= print_buf[255:248];
                    uart_valid <= 1'b1;
                    print_buf  <= {print_buf[247:0], 8'd0};
                    print_idx  <= print_idx + 5'd1;
                    if (print_idx == print_len - 5'd1) begin
                        printing <= 1'b0;
                        state    <= print_next_state;
                    end
                end
            end else begin

            case (state)
                // =============================================================
                S_WAIT_PHY: begin
                    if (phy_rst_done) begin
                        // Print "VER: "
                        print_buf[255:248] <= 8'h56; // V
                        print_buf[247:240] <= 8'h45; // E
                        print_buf[239:232] <= 8'h52; // R
                        print_buf[231:224] <= 8'h3A; // :
                        print_buf[223:216] <= 8'h20; // space
                        print_len <= 5'd5;
                        print_idx <= 5'd0;
                        printing  <= 1'b1;
                        print_next_state <= S_RD_VER;
                    end
                end

                // --- VERSION read ---
                S_RD_VER: begin
                    m_axi_araddr  <= A_VERSION;
                    m_axi_arvalid <= 1'b1;
                    m_axi_rready  <= 1'b1;
                    state <= S_RD_VER_W;
                end
                S_RD_VER_W: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        rd_data_r     <= m_axi_rdata;
                        m_axi_rready  <= 1'b0;
                        state <= S_PRINT_VER;
                    end
                end
                S_PRINT_VER: begin
                    // Print hex32 as 8 chars + CRLF
                    print_buf[255:248] <= hex_char(rd_data_r[31:28]);
                    print_buf[247:240] <= hex_char(rd_data_r[27:24]);
                    print_buf[239:232] <= hex_char(rd_data_r[23:20]);
                    print_buf[231:224] <= hex_char(rd_data_r[19:16]);
                    print_buf[223:216] <= hex_char(rd_data_r[15:12]);
                    print_buf[215:208] <= hex_char(rd_data_r[11:8]);
                    print_buf[207:200] <= hex_char(rd_data_r[7:4]);
                    print_buf[199:192] <= hex_char(rd_data_r[3:0]);
                    print_buf[191:184] <= 8'h0D;
                    print_buf[183:176] <= 8'h0A;
                    print_len <= 5'd10;
                    print_idx <= 5'd0;
                    printing  <= 1'b1;
                    print_next_state <= S_WR_SCR;
                end

                // --- SCRATCH write ---
                S_WR_SCR: begin
                    m_axi_awaddr  <= A_SCRATCH;
                    m_axi_awvalid <= 1'b1;
                    m_axi_wdata   <= 32'hDEADBEEF;
                    m_axi_wstrb   <= 4'hF;
                    m_axi_wvalid  <= 1'b1;
                    m_axi_bready  <= 1'b1;
                    state <= S_WR_SCR_W;
                end
                S_WR_SCR_W: begin
                    if (m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wready)  m_axi_wvalid  <= 1'b0;
                    if (wr_done) begin
                        m_axi_bready <= 1'b0;
                        state <= S_RD_SCR;
                    end
                end
                S_RD_SCR: begin
                    m_axi_araddr  <= A_SCRATCH;
                    m_axi_arvalid <= 1'b1;
                    m_axi_rready  <= 1'b1;
                    state <= S_RD_SCR_W;
                end
                S_RD_SCR_W: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= 1'b0;
                        // Print "SCR: "
                        print_buf[255:248] <= 8'h53; // S
                        print_buf[247:240] <= 8'h43; // C
                        print_buf[239:232] <= 8'h52; // R
                        print_buf[231:224] <= 8'h3A; // :
                        print_buf[223:216] <= 8'h20; // space
                        print_len <= 5'd5;
                        print_idx <= 5'd0;
                        printing  <= 1'b1;
                        print_next_state <= S_PRINT_SCR;
                    end
                end
                S_PRINT_SCR: begin
                    print_buf[255:248] <= hex_char(rd_data_r[31:28]);
                    print_buf[247:240] <= hex_char(rd_data_r[27:24]);
                    print_buf[239:232] <= hex_char(rd_data_r[23:20]);
                    print_buf[231:224] <= hex_char(rd_data_r[19:16]);
                    print_buf[223:216] <= hex_char(rd_data_r[15:12]);
                    print_buf[215:208] <= hex_char(rd_data_r[11:8]);
                    print_buf[207:200] <= hex_char(rd_data_r[7:4]);
                    print_buf[199:192] <= hex_char(rd_data_r[3:0]);
                    print_buf[191:184] <= 8'h0D;
                    print_buf[183:176] <= 8'h0A;
                    print_len <= 5'd10;
                    print_idx <= 5'd0;
                    printing  <= 1'b1;
                    print_next_state <= S_MDIO_PHY1;
                end

                // --- MDIO read PHY ID1 (reg 2) ---
                S_MDIO_PHY1: begin
                    m_axi_awaddr  <= A_MDIO_CMD;
                    m_axi_awvalid <= 1'b1;
                    m_axi_wdata   <= {20'd0, MDIO_RD_PHYIDR1};
                    m_axi_wstrb   <= 4'hF;
                    m_axi_wvalid  <= 1'b1;
                    m_axi_bready  <= 1'b1;
                    state <= S_MDIO_PHY1_W;
                end
                S_MDIO_PHY1_W: begin
                    if (m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wready)  m_axi_wvalid  <= 1'b0;
                    if (wr_done) begin
                        m_axi_bready  <= 1'b0;
                        mdio_poll_cnt <= 16'd0;
                        state <= S_MDIO_PHY1_P;
                    end
                end
                S_MDIO_PHY1_P: begin
                    // Poll STATUS register for mdio_busy (bit 2) to clear
                    mdio_poll_cnt <= mdio_poll_cnt + 16'd1;
                    if (mdio_poll_cnt[9:0] == 10'd0) begin // every 1024 cycles
                        m_axi_araddr  <= A_STATUS;
                        m_axi_arvalid <= 1'b1;
                        m_axi_rready  <= 1'b1;
                        state <= S_MDIO_PHY1_R;
                    end
                end
                S_MDIO_PHY1_R: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        m_axi_rready <= 1'b0;
                        if (m_axi_rdata[2] == 1'b0) begin
                            // MDIO done, read result
                            m_axi_araddr  <= A_MDIO_RDATA;
                            m_axi_arvalid <= 1'b1;
                            m_axi_rready  <= 1'b1;
                            state <= S_MDIO_PHY1_RW;
                        end else begin
                            state <= S_MDIO_PHY1_P;
                        end
                    end
                end
                S_MDIO_PHY1_RW: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        rd_data_r    <= m_axi_rdata;
                        phy1_id_r    <= m_axi_rdata[15:0];
                        m_axi_rready <= 1'b0;
                        // Print "PHY1: "
                        print_buf[255:248] <= 8'h50; // P
                        print_buf[247:240] <= 8'h48; // H
                        print_buf[239:232] <= 8'h59; // Y
                        print_buf[231:224] <= 8'h31; // 1
                        print_buf[223:216] <= 8'h3A; // :
                        print_buf[215:208] <= 8'h20; // space
                        print_len <= 5'd6;
                        print_idx <= 5'd0;
                        printing  <= 1'b1;
                        print_next_state <= S_PRINT_PHY1;
                    end
                end
                S_PRINT_PHY1: begin
                    setup_print_hex16(rd_data_r[15:0], S_MDIO_PHY2);
                end

                // --- MDIO read PHY ID2 (reg 3) - same pattern ---
                S_MDIO_PHY2: begin
                    m_axi_awaddr  <= A_MDIO_CMD;
                    m_axi_awvalid <= 1'b1;
                    m_axi_wdata   <= {20'd0, MDIO_RD_PHYIDR2};
                    m_axi_wstrb   <= 4'hF;
                    m_axi_wvalid  <= 1'b1;
                    m_axi_bready  <= 1'b1;
                    state <= S_MDIO_PHY2_W;
                end
                S_MDIO_PHY2_W: begin
                    if (m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wready)  m_axi_wvalid  <= 1'b0;
                    if (wr_done) begin
                        m_axi_bready  <= 1'b0;
                        mdio_poll_cnt <= 16'd0;
                        state <= S_MDIO_PHY2_P;
                    end
                end
                S_MDIO_PHY2_P: begin
                    mdio_poll_cnt <= mdio_poll_cnt + 16'd1;
                    if (mdio_poll_cnt[9:0] == 10'd0) begin
                        m_axi_araddr  <= A_STATUS;
                        m_axi_arvalid <= 1'b1;
                        m_axi_rready  <= 1'b1;
                        state <= S_MDIO_PHY2_R;
                    end
                end
                S_MDIO_PHY2_R: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        m_axi_rready <= 1'b0;
                        if (m_axi_rdata[2] == 1'b0) begin
                            m_axi_araddr  <= A_MDIO_RDATA;
                            m_axi_arvalid <= 1'b1;
                            m_axi_rready  <= 1'b1;
                            state <= S_MDIO_PHY2_RW;
                        end else begin
                            state <= S_MDIO_PHY2_P;
                        end
                    end
                end
                S_MDIO_PHY2_RW: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= 1'b0;
                        // Check PHY ID: PHYIDR1 should have been 0x2000
                        // phy1_id_r was latched when PHY1 completed; compare both here
                        phy_id_ok <= (phy1_id_r == 16'h2000) &&
                                     (m_axi_rdata[15:4] == 12'h5C9);
                        print_buf[255:248] <= 8'h50; // P
                        print_buf[247:240] <= 8'h48; // H
                        print_buf[239:232] <= 8'h59; // Y
                        print_buf[231:224] <= 8'h32; // 2
                        print_buf[223:216] <= 8'h3A; // :
                        print_buf[215:208] <= 8'h20;
                        print_len <= 5'd6;
                        print_idx <= 5'd0;
                        printing  <= 1'b1;
                        print_next_state <= S_PRINT_PHY2;
                    end
                end
                S_PRINT_PHY2: begin
                    setup_print_hex16(rd_data_r[15:0], S_MDIO_WR_BMCR);
                end

                // --- MDIO read BMSR (reg 1) for link status ---
                S_MDIO_BMSR: begin
                    m_axi_awaddr  <= A_MDIO_CMD;
                    m_axi_awvalid <= 1'b1;
                    m_axi_wdata   <= {20'd0, MDIO_RD_BMSR};
                    m_axi_wstrb   <= 4'hF;
                    m_axi_wvalid  <= 1'b1;
                    m_axi_bready  <= 1'b1;
                    state <= S_MDIO_BMSR_W;
                end
                S_MDIO_BMSR_W: begin
                    if (m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wready)  m_axi_wvalid  <= 1'b0;
                    if (wr_done) begin
                        m_axi_bready  <= 1'b0;
                        mdio_poll_cnt <= 16'd0;
                        state <= S_MDIO_BMSR_P;
                    end
                end
                S_MDIO_BMSR_P: begin
                    wait_cnt      <= wait_cnt + 32'd1;
                    mdio_poll_cnt <= mdio_poll_cnt + 16'd1;
                    if (mdio_poll_cnt[9:0] == 10'd0) begin
                        m_axi_araddr  <= A_STATUS;
                        m_axi_arvalid <= 1'b1;
                        m_axi_rready  <= 1'b1;
                        state <= S_MDIO_BMSR_R;
                    end
                end
                S_MDIO_BMSR_R: begin
                    wait_cnt <= wait_cnt + 32'd1;
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        m_axi_rready <= 1'b0;
                        if (m_axi_rdata[2] == 1'b0) begin
                            m_axi_araddr  <= A_MDIO_RDATA;
                            m_axi_arvalid <= 1'b1;
                            m_axi_rready  <= 1'b1;
                            state <= S_MDIO_BMSR_RW;
                        end else begin
                            state <= S_MDIO_BMSR_P;
                        end
                    end
                end
                S_MDIO_BMSR_RW: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= 1'b0;
                        if (m_axi_rdata[2]) begin
                            // Link is up
                            link_up <= 1'b1;
                            state   <= S_PRINT_LINK;
                        end else if (wait_cnt < 32'd300_000_000) begin
                            // No link yet, retry after brief delay (3s total timeout)
                            state <= S_MDIO_BMSR;
                        end else begin
                            // Timeout — no link
                            link_up <= 1'b0;
                            state   <= S_PRINT_LINK;
                        end
                    end
                end
                S_PRINT_LINK: begin
                    if (link_up) begin
                        // "LINK: UP\r\n"
                        print_buf[255:248] <= 8'h4C; print_buf[247:240] <= 8'h49;
                        print_buf[239:232] <= 8'h4E; print_buf[231:224] <= 8'h4B;
                        print_buf[223:216] <= 8'h3A; print_buf[215:208] <= 8'h20;
                        print_buf[207:200] <= 8'h55; print_buf[199:192] <= 8'h50;
                        print_buf[191:184] <= 8'h0D; print_buf[183:176] <= 8'h0A;
                        print_len <= 5'd10;
                    end else begin
                        // "LINK: DN\r\n"
                        print_buf[255:248] <= 8'h4C; print_buf[247:240] <= 8'h49;
                        print_buf[239:232] <= 8'h4E; print_buf[231:224] <= 8'h4B;
                        print_buf[223:216] <= 8'h3A; print_buf[215:208] <= 8'h20;
                        print_buf[207:200] <= 8'h44; print_buf[199:192] <= 8'h4E;
                        print_buf[191:184] <= 8'h0D; print_buf[183:176] <= 8'h0A;
                        print_len <= 5'd10;
                    end
                    print_idx <= 5'd0;
                    printing  <= 1'b1;
                    print_next_state <= S_EN_MAC;
                end

                // --- Enable MAC (tx+rx+promisc) ---
                S_EN_MAC: begin
                    m_axi_awaddr  <= A_CTRL;
                    m_axi_awvalid <= 1'b1;
                    m_axi_wdata   <= 32'h0000_0007;
                    m_axi_wstrb   <= 4'hF;
                    m_axi_wvalid  <= 1'b1;
                    m_axi_bready  <= 1'b1;
                    state <= S_EN_MAC_W;
                end
                S_EN_MAC_W: begin
                    if (m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wready)  m_axi_wvalid  <= 1'b0;
                    if (wr_done) begin
                        m_axi_bready <= 1'b0;
                        if (link_up) begin
                            arp_idx <= 8'd0;
                            state   <= S_SEND_ARP;
                        end else begin
                            state <= S_PRINT_DONE;
                        end
                    end
                end

                // --- Send gratuitous ARP ---
                S_SEND_ARP: begin
                    tx_tdata  <= arp_frame[arp_idx];
                    tx_tvalid <= 1'b1;
                    tx_tlast  <= (arp_idx == 8'd41);
                    state <= S_SEND_ARP_D;
                end
                S_SEND_ARP_D: begin
                    if (tx_tready) begin
                        if (arp_idx == 8'd41) begin
                            tx_tvalid <= 1'b0;
                            tx_tlast  <= 1'b0;
                            // Wait for frame to go through
                            wait_cnt <= 32'd0;
                            state    <= S_CHK_TX;
                        end else begin
                            arp_idx <= arp_idx + 8'd1;
                            state   <= S_SEND_ARP;
                        end
                    end
                end

                // --- Check TX counter ---
                S_CHK_TX: begin
                    wait_cnt <= wait_cnt + 32'd1;
                    if (wait_cnt > 32'd500_000) begin // 5ms wait
                        m_axi_araddr  <= A_TX_FRAME;
                        m_axi_arvalid <= 1'b1;
                        m_axi_rready  <= 1'b1;
                        state <= S_CHK_TX_W;
                    end
                end
                S_CHK_TX_W: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= 1'b0;
                        tx_done      <= (m_axi_rdata != 32'd0);
                        arp_tx_active <= 1'b0; // hand TX to arp_responder
                        // "TX: "
                        print_buf[255:248] <= 8'h54; print_buf[247:240] <= 8'h58;
                        print_buf[239:232] <= 8'h3A; print_buf[231:224] <= 8'h20;
                        print_len <= 5'd4;
                        print_idx <= 5'd0;
                        printing  <= 1'b1;
                        print_next_state <= S_PRINT_TX;
                    end
                end
                S_PRINT_TX: begin
                    wait_cnt <= 32'd0;  // reset for RX wait timeout
                    setup_print_hex16(rd_data_r[15:0], S_WAIT_RX);
                end

                // --- Wait for RX frame ---
                S_WAIT_RX: begin
                    wait_cnt <= wait_cnt + 32'd1;
                    if (wait_cnt > 32'd200_000_000) begin // 2s timeout
                        m_axi_araddr  <= A_RX_FRAME;
                        m_axi_arvalid <= 1'b1;
                        m_axi_rready  <= 1'b1;
                        state <= S_CHK_RX;
                    end else if (wait_cnt[19:0] == 20'd0) begin
                        // Poll every ~10ms
                        m_axi_araddr  <= A_RX_FRAME;
                        m_axi_arvalid <= 1'b1;
                        m_axi_rready  <= 1'b1;
                        state <= S_CHK_RX;
                    end
                end
                S_CHK_RX: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= 1'b0;
                        if (m_axi_rdata != 32'd0) begin
                            rx_done <= 1'b1;
                            // "RX: "
                            print_buf[255:248] <= 8'h52; print_buf[247:240] <= 8'h58;
                            print_buf[239:232] <= 8'h3A; print_buf[231:224] <= 8'h20;
                            print_len <= 5'd4;
                            print_idx <= 5'd0;
                            printing  <= 1'b1;
                            print_next_state <= S_PRINT_RX;
                        end else if (wait_cnt > 32'd200_000_000) begin
                            // Timeout
                            print_buf[255:248] <= 8'h52; print_buf[247:240] <= 8'h58;
                            print_buf[239:232] <= 8'h3A; print_buf[231:224] <= 8'h20;
                            print_buf[223:216] <= 8'h54; print_buf[215:208] <= 8'h4F;  // TO
                            print_buf[207:200] <= 8'h0D; print_buf[199:192] <= 8'h0A;
                            print_len <= 5'd8;
                            print_idx <= 5'd0;
                            printing  <= 1'b1;
                            print_next_state <= S_PRINT_DONE;
                        end else begin
                            state <= S_WAIT_RX;
                        end
                    end
                end
                S_PRINT_RX: begin
                    setup_print_hex16(rd_data_r[15:0], S_PRINT_DONE);
                end

                // --- MDIO write verification: write BMCR loopback, read back ---
                S_MDIO_WR_BMCR: begin
                    // First write WDATA, then CMD in same AXI write (CMD triggers go)
                    m_axi_awaddr  <= A_MDIO_WDATA;
                    m_axi_awvalid <= 1'b1;
                    m_axi_wdata   <= {16'd0, BMCR_VALUE};
                    m_axi_wstrb   <= 4'hF;
                    m_axi_wvalid  <= 1'b1;
                    m_axi_bready  <= 1'b1;
                    state <= S_MDIO_WR_BMCR_W;
                end
                S_MDIO_WR_BMCR_W: begin
                    if (m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wready)  m_axi_wvalid  <= 1'b0;
                    if (wr_done) begin
                        m_axi_bready  <= 1'b0;
                        // Now send the CMD (write=1, phy=1, reg=0, go=1)
                        m_axi_awaddr  <= A_MDIO_CMD;
                        m_axi_awvalid <= 1'b1;
                        m_axi_wdata   <= {20'd0, MDIO_WR_BMCR};
                        m_axi_wstrb   <= 4'hF;
                        m_axi_wvalid  <= 1'b1;
                        m_axi_bready  <= 1'b1;
                        mdio_poll_cnt <= 16'd1;  // start at 1 so first poll waits for CMD write to complete
                        state <= S_MDIO_WR_BMCR_P;
                    end
                end
                S_MDIO_WR_BMCR_P: begin
                    if (m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wready)  m_axi_wvalid  <= 1'b0;
                    if (wr_done)       m_axi_bready  <= 1'b0;
                    mdio_poll_cnt <= mdio_poll_cnt + 16'd1;
                    if (mdio_poll_cnt[9:0] == 10'd0) begin
                        m_axi_araddr  <= A_STATUS;
                        m_axi_arvalid <= 1'b1;
                        m_axi_rready  <= 1'b1;
                        state <= S_MDIO_WR_BMCR_R;
                    end
                end
                S_MDIO_WR_BMCR_R: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        m_axi_rready <= 1'b0;
                        if (m_axi_rdata[2] == 1'b0)
                            state <= S_MDIO_RD_BMCR;
                        else
                            state <= S_MDIO_WR_BMCR_P;
                    end
                end
                // Read BMCR back to verify write
                S_MDIO_RD_BMCR: begin
                    m_axi_awaddr  <= A_MDIO_CMD;
                    m_axi_awvalid <= 1'b1;
                    m_axi_wdata   <= {20'd0, MDIO_RD_BMCR};
                    m_axi_wstrb   <= 4'hF;
                    m_axi_wvalid  <= 1'b1;
                    m_axi_bready  <= 1'b1;
                    state <= S_MDIO_RD_BMCR_W;
                end
                S_MDIO_RD_BMCR_W: begin
                    if (m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wready)  m_axi_wvalid  <= 1'b0;
                    if (wr_done) begin
                        m_axi_bready  <= 1'b0;
                        mdio_poll_cnt <= 16'd0;
                        state <= S_MDIO_RD_BMCR_P;
                    end
                end
                S_MDIO_RD_BMCR_P: begin
                    mdio_poll_cnt <= mdio_poll_cnt + 16'd1;
                    if (mdio_poll_cnt[9:0] == 10'd0) begin
                        m_axi_araddr  <= A_STATUS;
                        m_axi_arvalid <= 1'b1;
                        m_axi_rready  <= 1'b1;
                        state <= S_MDIO_RD_BMCR_R;
                    end
                end
                S_MDIO_RD_BMCR_R: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        m_axi_rready <= 1'b0;
                        if (m_axi_rdata[2] == 1'b0) begin
                            m_axi_araddr  <= A_MDIO_RDATA;
                            m_axi_arvalid <= 1'b1;
                            m_axi_rready  <= 1'b1;
                            state <= S_MDIO_RD_BMCR_RW;
                        end else begin
                            state <= S_MDIO_RD_BMCR_P;
                        end
                    end
                end
                S_MDIO_RD_BMCR_RW: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= 1'b0;
                        // Print "BMCR: "
                        print_buf[255:248] <= 8'h42; // B
                        print_buf[247:240] <= 8'h4D; // M
                        print_buf[239:232] <= 8'h43; // C
                        print_buf[231:224] <= 8'h52; // R
                        print_buf[223:216] <= 8'h3A; // :
                        print_buf[215:208] <= 8'h20; // space
                        print_len <= 5'd6;
                        print_idx <= 5'd0;
                        printing  <= 1'b1;
                        print_next_state <= S_PRINT_BMCR;
                    end
                end
                S_PRINT_BMCR: begin
                    wait_cnt <= 32'd0;  // reset link-up timeout counter
                    setup_print_hex16(rd_data_r[15:0], S_MDIO_BMSR);
                end

                // --- Done ---
                S_PRINT_DONE: begin
                    // "DONE\r\n"
                    print_buf[255:248] <= 8'h44; print_buf[247:240] <= 8'h4F;
                    print_buf[239:232] <= 8'h4E; print_buf[231:224] <= 8'h45;
                    print_buf[223:216] <= 8'h0D; print_buf[215:208] <= 8'h0A;
                    print_len <= 5'd6;
                    print_idx <= 5'd0;
                    printing  <= 1'b1;
                    print_next_state <= S_STAT_WAIT;
                    wait_cnt <= 32'd0;
                end

                // ========== Periodic stats dump (~1s cadence) ==========
                // Lines: "RXF: XXXXXXXX", "RXB: XXXXXXXX", "RXE: XXXXXXXX",
                //        "OVF: XXXXXXXX". Host udp_throughput.py parses and
                //        computes Mbps / pps / loss across windows.
                S_STAT_WAIT: begin
                    wait_cnt <= wait_cnt + 32'd1;
                    if (wait_cnt >= 32'd100_000_000) begin
                        wait_cnt <= 32'd0;
                        state    <= S_STAT_RD_RXF;
                    end
                end

                S_STAT_RD_RXF: begin
                    m_axi_araddr  <= A_RX_FRAME;
                    m_axi_arvalid <= 1'b1;
                    m_axi_rready  <= 1'b1;
                    state         <= S_STAT_RD_RXF_W;
                end
                S_STAT_RD_RXF_W: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= 1'b0;
                        // "RXF: " (5 chars)
                        print_buf[255:248] <= 8'h52; print_buf[247:240] <= 8'h58;
                        print_buf[239:232] <= 8'h46; print_buf[231:224] <= 8'h3A;
                        print_buf[223:216] <= 8'h20;
                        print_len <= 5'd5;
                        print_idx <= 5'd0;
                        printing  <= 1'b1;
                        print_next_state <= S_STAT_PRINT_RXF;
                    end
                end
                S_STAT_PRINT_RXF: setup_print_hex32(rd_data_r, S_STAT_RD_RXB);

                S_STAT_RD_RXB: begin
                    m_axi_araddr  <= A_RX_BYTE;
                    m_axi_arvalid <= 1'b1;
                    m_axi_rready  <= 1'b1;
                    state         <= S_STAT_RD_RXB_W;
                end
                S_STAT_RD_RXB_W: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= 1'b0;
                        // "RXB: "
                        print_buf[255:248] <= 8'h52; print_buf[247:240] <= 8'h58;
                        print_buf[239:232] <= 8'h42; print_buf[231:224] <= 8'h3A;
                        print_buf[223:216] <= 8'h20;
                        print_len <= 5'd5;
                        print_idx <= 5'd0;
                        printing  <= 1'b1;
                        print_next_state <= S_STAT_PRINT_RXB;
                    end
                end
                S_STAT_PRINT_RXB: setup_print_hex32(rd_data_r, S_STAT_RD_RXE);

                S_STAT_RD_RXE: begin
                    m_axi_araddr  <= A_RX_ERR;
                    m_axi_arvalid <= 1'b1;
                    m_axi_rready  <= 1'b1;
                    state         <= S_STAT_RD_RXE_W;
                end
                S_STAT_RD_RXE_W: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= 1'b0;
                        // "RXE: "
                        print_buf[255:248] <= 8'h52; print_buf[247:240] <= 8'h58;
                        print_buf[239:232] <= 8'h45; print_buf[231:224] <= 8'h3A;
                        print_buf[223:216] <= 8'h20;
                        print_len <= 5'd5;
                        print_idx <= 5'd0;
                        printing  <= 1'b1;
                        print_next_state <= S_STAT_PRINT_RXE;
                    end
                end
                S_STAT_PRINT_RXE: setup_print_hex32(rd_data_r, S_STAT_RD_OVF);

                S_STAT_RD_OVF: begin
                    m_axi_araddr  <= A_RX_OVERFLOW;
                    m_axi_arvalid <= 1'b1;
                    m_axi_rready  <= 1'b1;
                    state         <= S_STAT_RD_OVF_W;
                end
                S_STAT_RD_OVF_W: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (rd_done) begin
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= 1'b0;
                        // "OVF: "
                        print_buf[255:248] <= 8'h4F; print_buf[247:240] <= 8'h56;
                        print_buf[239:232] <= 8'h46; print_buf[231:224] <= 8'h3A;
                        print_buf[223:216] <= 8'h20;
                        print_len <= 5'd5;
                        print_idx <= 5'd0;
                        printing  <= 1'b1;
                        print_next_state <= S_STAT_PRINT_OVF;
                    end
                end
                S_STAT_PRINT_OVF: setup_print_hex32(rd_data_r, S_STAT_WAIT);

                S_IDLE: begin
                    // Reachable only via the default branch; identical to
                    // S_STAT_WAIT semantics so we never get stuck.
                    state <= S_STAT_WAIT;
                end

                default: state <= S_IDLE;
            endcase

            end // !printing
        end
    end

endmodule
