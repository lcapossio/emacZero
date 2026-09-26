// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_gmii_rx_line_rate.v - sustained 1 Gb/s RX through eth_mac_sys (GMII)
// A PHY model drives the GMII RX pins with back-to-back frames at full line
// rate: 7-byte preamble + SFD, the frame with a real FCS, then the minimum
// 12-byte IFG, from a PHY clock 100 ppm fast. The MAC's clk runs at 125 MHz
// 100 ppm slow, the worst legal pairing for a 125 MHz system clock. Checks
// that every frame (minimum, MTU and 9018-byte jumbo) arrives byte-exact with
// no terror and no overflow or alignment errors.
//
// This is the case a 100 MHz clk cannot sustain: define GMII_RX_SLOW_SYS to
// run clk at 100 MHz and the RX CDC FIFO overflows within a few dozen frames.
// gmii_cdc reports that overflow as truncated frames (terror, RX_ERR_ALIGN);
// RX_ERR_OVERFLOW counts only the MAC's RX AXIS buffer and stays 0.
// eth_mac_sys therefore refuses to elaborate a 1G-capable build with
// CLK_FREQ_HZ below 125 MHz; this test is what that rule rests on.
// =============================================================================
`timescale 1ns / 10fs
`include "version.vh"

module tb_gmii_rx_line_rate;

    localparam MAX_FRAME = 9018;
    localparam N_FRAMES  = 60;

`ifdef GMII_RX_SLOW_SYS
    localparam real SYS_HALF = 5.0;         // 100 MHz: expected to overflow
`else
    localparam real SYS_HALF = 4.0004;      // 125 MHz - 100 ppm
`endif
    localparam real PHY_HALF = 3.9996;      // 125 MHz + 100 ppm

    reg sys_clk, phy_clk, rst_n;
    initial begin sys_clk = 0; phy_clk = 0; end
    always #(SYS_HALF) sys_clk = ~sys_clk;
    always #(PHY_HALF) phy_clk = ~phy_clk;

    // ---- AXI4-Lite ----
    reg  [7:0]  awaddr;  reg awvalid;  wire awready;
    reg  [31:0] wdata;   reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp;   wire bvalid;  reg bready;
    reg  [7:0]  araddr;  reg arvalid;  wire arready;
    wire [31:0] rdata;   wire [1:0] rresp; wire rvalid; reg rready;

    // ---- AXI4-Stream RX ----
    wire [7:0]  rx_tdata;
    wire        rx_tvalid;
    wire        rx_tlast;
    wire        rx_terror;
    wire        rx_tsof;

    // ---- GMII RX pins, driven by the PHY model ----
    reg  [7:0]  gmii_rxd;
    reg         gmii_rx_dv;
    reg         gmii_rx_er;

    wire irq;

    eth_mac_sys #(
        .PHY_INTERFACE ("GMII"),
        .MAX_FRAME     (MAX_FRAME),
        .CLK_FREQ_HZ   (125_000_000)
    ) uut (
        .clk            (sys_clk),
        .rst_n          (rst_n),
        .s_axi_awaddr   (awaddr),
        .s_axi_awvalid  (awvalid),
        .s_axi_awready  (awready),
        .s_axi_wdata    (wdata),
        .s_axi_wstrb    (wstrb),
        .s_axi_wvalid   (wvalid),
        .s_axi_wready   (wready),
        .s_axi_bresp    (bresp),
        .s_axi_bvalid   (bvalid),
        .s_axi_bready   (bready),
        .s_axi_araddr   (araddr),
        .s_axi_arvalid  (arvalid),
        .s_axi_arready  (arready),
        .s_axi_rdata    (rdata),
        .s_axi_rresp    (rresp),
        .s_axi_rvalid   (rvalid),
        .s_axi_rready   (rready),
        .s_axis_tdata   (8'd0),
        .s_axis_tvalid  (1'b0),
        .s_axis_tready  (),
        .s_axis_tlast   (1'b0),
        .m_axis_tdata   (rx_tdata),
        .m_axis_tvalid  (rx_tvalid),
        .m_axis_tready  (1'b1),
        .m_axis_tlast   (rx_tlast),
        .m_axis_terror  (rx_terror),
        .m_axis_tsof    (rx_tsof),
        .mii_txd        (),
        .mii_tx_en      (),
        .mii_tx_clk     (1'b0),
        .mii_rxd        (4'd0),
        .mii_rx_dv      (1'b0),
        .mii_rx_er      (1'b0),
        .mii_rx_clk     (1'b0),
        .mii_col        (1'b0),
        .mii_crs        (1'b0),
        .clk_125        (phy_clk),
        .clk_125_90     (phy_clk),
        .clk_25         (1'b0),
        .clk_2_5        (1'b0),
        .rgmii_txd      (),
        .rgmii_tx_ctl   (),
        .rgmii_txc      (),
        .rgmii_rxd      (4'd0),
        .rgmii_rx_ctl   (1'b0),
        .rgmii_rxc      (1'b0),
        .phy_gmii_txd     (),
        .phy_gmii_tx_en   (),
        .phy_gmii_tx_er   (),
        .phy_gmii_txc     (),
        .phy_gmii_rx_clk  (phy_clk),
        .phy_gmii_rxd     (gmii_rxd),
        .phy_gmii_rx_dv   (gmii_rx_dv),
        .phy_gmii_rx_er   (gmii_rx_er),
        .mdc            (),
        .mdio_i         (1'b1),
        .mdio_o         (),
        .mdio_oe        (),
        .cfg_ip_addr    (),
        .irq            (irq)
    );

    // ---- AXI4-Lite BFM ----
    reg [31:0] rd_result;

    task axi_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(negedge sys_clk);
            awaddr = addr; awvalid = 1;
            wdata  = data; wstrb = 4'hF; wvalid = 1;
            bready = 1;
            @(posedge sys_clk);
            while (!bvalid) @(posedge sys_clk);
            @(negedge sys_clk);
            awvalid = 0; wvalid = 0; bready = 0;
        end
    endtask

    task axi_read;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            @(negedge sys_clk);
            araddr = addr; arvalid = 1; rready = 1;
            @(posedge sys_clk);
            while (!rvalid) @(posedge sys_clk);
            data = rdata;
            @(negedge sys_clk);
            arvalid = 0; rready = 0;
        end
    endtask

    integer pass_cnt, fail_cnt;

    task check_int;
        input [255:0] name;
        input integer actual;
        input integer expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s = %0d", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = %0d, expected %0d", name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // =========================================================================
    // Frame plan: payload length per frame; payload byte k = (n * 7 + k)
    // =========================================================================
    function integer plen;
        input integer n;
        begin
            if (n % 10 == 9)      plen = 9000;   // MAX_FRAME on the wire
            else if (n % 6 == 0)  plen = 46;     // minimum frame
            else if (n % 6 == 5)  plen = 300;
            else                  plen = 1500;   // MTU
        end
    endfunction

    function [7:0] frame_byte;       // byte k of frame n, DA through payload
        input integer n;
        input integer k;
        begin
            if (k < 6)        frame_byte = 8'hFF;
            else if (k < 12)  frame_byte = (k == 6) ? 8'h02 : (k == 11) ? 8'h01 : 8'h00;
            else if (k == 12) frame_byte = 8'h08;
            else if (k == 13) frame_byte = 8'h00;
            else              frame_byte = (n * 7 + k - 14) & 8'hFF;
        end
    endfunction

    function [31:0] crc32_byte;      // reflected CRC-32, polynomial 0xEDB88320
        input [31:0] crc;
        input [7:0]  b;
        integer i;
        reg [31:0] c;
        begin
            c = crc ^ {24'd0, b};
            for (i = 0; i < 8; i = i + 1)
                c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
            crc32_byte = c;
        end
    endfunction

    // =========================================================================
    // PHY model: back-to-back frames, 12-byte IFG, driven off phy_clk
    // =========================================================================
    reg phy_done;

    task phy_send;
        input integer n;
        integer k, total;
        reg [31:0] crc;
        begin
            total = 14 + plen(n);
            crc   = 32'hFFFFFFFF;
            for (k = 0; k < 8; k = k + 1) begin
                @(negedge phy_clk);
                gmii_rx_dv = 1'b1;
                gmii_rxd   = (k < 7) ? 8'h55 : 8'hD5;
            end
            for (k = 0; k < total; k = k + 1) begin
                @(negedge phy_clk);
                gmii_rxd = frame_byte(n, k);
                crc      = crc32_byte(crc, frame_byte(n, k));
            end
            crc = ~crc;
            for (k = 0; k < 4; k = k + 1) begin
                @(negedge phy_clk);
                gmii_rxd = crc[8*k +: 8];
            end
            for (k = 0; k < 12; k = k + 1) begin
                @(negedge phy_clk);
                gmii_rx_dv = 1'b0;
                gmii_rxd   = 8'h00;
            end
        end
    endtask

    // =========================================================================
    // RX checker: length and every byte of each frame, in order
    // =========================================================================
    integer rx_frames, rx_bad, rx_err, rx_pos, rx_bad_bytes;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            rx_frames    = 0;
            rx_bad       = 0;
            rx_err       = 0;
            rx_pos       = 0;
            rx_bad_bytes = 0;
        end else if (rx_tvalid) begin
            if (rx_terror) rx_err = rx_err + 1;
            if (rx_tdata !== frame_byte(rx_frames, rx_pos))
                rx_bad_bytes = rx_bad_bytes + 1;
            if (rx_tlast) begin
                if (rx_bad_bytes != 0 || rx_pos + 1 != 14 + plen(rx_frames)) begin
                    if (rx_bad < 4)
                        $display("  frame %0d: len %0d (expected %0d), %0d bad bytes",
                                 rx_frames, rx_pos + 1, 14 + plen(rx_frames), rx_bad_bytes);
                    rx_bad = rx_bad + 1;
                end
                rx_frames    = rx_frames + 1;
                rx_pos       = 0;
                rx_bad_bytes = 0;
            end else begin
                rx_pos = rx_pos + 1;
            end
        end
    end

    integer n, t;

    initial begin
        pass_cnt = 0; fail_cnt = 0; phy_done = 0;
        rst_n = 0;
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arvalid = 0; rready = 0;
        gmii_rxd = 0; gmii_rx_dv = 0; gmii_rx_er = 0;
        #100;
        rst_n = 1;
        #300;

`ifdef GMII_RX_SLOW_SYS
        $display("GMII RX line rate: clk 100 MHz (expected to FAIL)");
`else
        $display("GMII RX line rate: clk 125 MHz - 100 ppm, PHY 125 MHz + 100 ppm");
`endif
        // rx_en + promisc + jumbo_en; accept broadcast
        axi_write(8'h04, 32'h0000_0046);
        axi_write(8'h0C, 32'hFF_FF_FF_FF);
        axi_write(8'h10, 32'h0000_FF_FF);
        #200;

        for (n = 0; n < N_FRAMES; n = n + 1)
            phy_send(n);

        // Drain: the reader may be a frame behind the wire.
        t = 0;
        while (rx_frames < N_FRAMES && t < 200) begin
            #1000;
            t = t + 1;
        end
        #2000;

        check_int("frames received", rx_frames, N_FRAMES);
        check_int("frames with wrong length/content", rx_bad, 0);
        check_int("terror beats", rx_err, 0);
        axi_read(8'h30, rd_result);
        check_int("RX_FRAME_CNT", rd_result, N_FRAMES);
        axi_read(8'h38, rd_result);
        check_int("RX_ERR", rd_result, 0);
        axi_read(8'h4C, rd_result);
        check_int("RX_ERR_ALIGN", rd_result, 0);
        axi_read(8'h50, rd_result);
        check_int("RX_ERR_OVERFLOW", rd_result, 0);

        #100;
        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #10000000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
