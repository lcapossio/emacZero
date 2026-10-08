// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_eth_mac_sys_csum_loop.v - TX and RX checksum offload through eth_mac_sys
//
// eth_mac_sys built with TX_CSUM_OFFLOAD=1 and RX_CSUM_OFFLOAD=1, MII TX
// looped back to MII RX. Sends an IPv4 UDP frame whose IP and UDP checksums
// are both wrong, and checks the CSR-level behaviour:
//   A. CTRL[7]=1, CTRL[9]=1: TX inserts both checksums, RX accepts the frame
//      (no terror), RX_ERR_CSUM stays 0.
//   B. CTRL[7]=0, CTRL[9]=1: the wrong checksums reach RX, the frame ends
//      with terror, RX_ERR_CSUM and RX_ERR count it.
//   C. CTRL[7]=0, CTRL[9]=0: delivered unchecked, no terror, no count.
//   D. Writing RX_ERR_CSUM clears it.
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_eth_mac_sys_csum_loop;

    reg clk;
    reg mii_clk;
    reg rst_n;

    initial clk = 0;
    always #5 clk = ~clk;          // 100 MHz
    initial mii_clk = 0;
    always #20 mii_clk = ~mii_clk; // 25 MHz

    reg  [7:0]  awaddr;  reg awvalid;  wire awready;
    reg  [31:0] wdata;   reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp;   wire bvalid;  reg bready;
    reg  [7:0]  araddr;  reg arvalid;  wire arready;
    wire [31:0] rdata;   wire [1:0] rresp; wire rvalid; reg rready;

    reg  [7:0]  tx_tdata;
    reg         tx_tvalid;
    wire        tx_tready;
    reg         tx_tlast;

    wire [7:0]  rx_tdata;
    wire        rx_tvalid;
    wire        rx_tlast;
    wire        rx_terror;
    wire        rx_tsof;

    wire [3:0]  mii_txd;
    wire        mii_tx_en;
    reg  [3:0]  mii_rxd_r;
    reg         mii_rx_dv_r;
    always @(posedge mii_clk) begin
        mii_rxd_r   <= mii_txd;
        mii_rx_dv_r <= mii_tx_en;
    end

    wire mdio_o;

    eth_mac_sys #(
        .PHY_INTERFACE   ("MII"),
        .MAX_FRAME       (1518),
        .TX_CSUM_OFFLOAD (1),
        .RX_CSUM_OFFLOAD (1)
    ) uut (
        .clk            (clk),
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
        .s_axis_tdata   (tx_tdata),
        .s_axis_tvalid  (tx_tvalid),
        .s_axis_tready  (tx_tready),
        .s_axis_tlast   (tx_tlast),
        .m_axis_tdata   (rx_tdata),
        .m_axis_tvalid  (rx_tvalid),
        .m_axis_tready  (1'b1),
        .m_axis_tlast   (rx_tlast),
        .m_axis_terror  (rx_terror),
        .m_axis_tsof    (rx_tsof),
        .mii_txd        (mii_txd),
        .mii_tx_en      (mii_tx_en),
        .mii_tx_clk     (mii_clk),
        .mii_rxd        (mii_rxd_r),
        .mii_rx_dv      (mii_rx_dv_r),
        .mii_rx_er      (1'b0),
        .mii_rx_clk     (mii_clk),
        .mii_col        (1'b0),
        .mii_crs        (1'b0),
        .clk_125        (1'b0),
        .clk_125_90     (1'b0),
        .clk_25         (1'b0),
        .clk_2_5        (1'b0),
        .rgmii_txd      (),
        .rgmii_tx_ctl   (),
        .rgmii_txc      (),
        .rgmii_rxd      (4'd0),
        .rgmii_rx_ctl   (1'b0),
        .rgmii_rxc      (1'b0),
        .mdc            (),
        .mdio_i         (mdio_o),
        .mdio_o         (mdio_o),
        .mdio_oe        (),
        .irq            ()
    );

    // ---- AXI4-Lite BFM ----
    task axi_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            awaddr = addr; awvalid = 1;
            wdata  = data; wstrb = 4'hF; wvalid = 1;
            bready = 1;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            @(negedge clk);
            awvalid = 0; wvalid = 0; bready = 0;
        end
    endtask

    task axi_read;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            @(negedge clk);
            araddr = addr; arvalid = 1; rready = 1;
            @(posedge clk);
            while (!rvalid) @(posedge clk);
            data = rdata;
            @(negedge clk);
            arvalid = 0; rready = 0;
        end
    endtask

    integer pass_cnt, fail_cnt;

    task check32;
        input [255:0] name;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s = 0x%08x", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = 0x%08x, expected 0x%08x", name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ---- Test frame: IPv4 UDP, both checksums wrong ----
    //   [14..33] IP header, total length 46, csum 0xDEAD (correct: 0xA440)
    //   [34..41] UDP header, length 26, csum 0xBEEF (correct: 0x4EF6)
    //   [42..59] payload = byte index
    // Correct values from the Python reference in sim/cocotb/lib/csum.py.
    localparam FRAME_LEN = 60;
    reg [7:0] frame [0:FRAME_LEN-1];
    integer i;
    initial begin
        for (i = 0; i < 6; i = i + 1) frame[i] = 8'hFF;
        frame[6]=8'h02; frame[7]=8'h11; frame[8]=8'h22;
        frame[9]=8'h33; frame[10]=8'h44; frame[11]=8'h55;
        frame[12]=8'h08; frame[13]=8'h00;
        frame[14]=8'h45; frame[15]=8'h00;
        frame[16]=8'h00; frame[17]=8'h2E;
        frame[18]=8'h12; frame[19]=8'h34;
        frame[20]=8'h40; frame[21]=8'h00;
        frame[22]=8'h40; frame[23]=8'h11;
        frame[24]=8'hDE; frame[25]=8'hAD;
        frame[26]=8'hC0; frame[27]=8'hA8; frame[28]=8'h01; frame[29]=8'h32;
        frame[30]=8'hC0; frame[31]=8'hA8; frame[32]=8'h01; frame[33]=8'hC8;
        frame[34]=8'h12; frame[35]=8'h34;
        frame[36]=8'h56; frame[37]=8'h78;
        frame[38]=8'h00; frame[39]=8'h1A;
        frame[40]=8'hBE; frame[41]=8'hEF;
        for (i = 42; i < FRAME_LEN; i = i + 1)
            frame[i] = i[7:0];
    end

    task send_frame;
        integer k;
        begin
            for (k = 0; k < FRAME_LEN; k = k + 1) begin
                @(negedge clk);
                tx_tdata  = frame[k];
                tx_tvalid = 1'b1;
                tx_tlast  = (k == FRAME_LEN - 1);
                @(posedge clk);
                while (!tx_tready) @(posedge clk);
            end
            @(negedge clk);
            tx_tvalid = 1'b0;
            tx_tlast  = 1'b0;
        end
    endtask

    // ---- RX capture: last frame's checksum fields and terror ----
    integer    rx_pos;
    integer    rx_frames;
    reg [15:0] rx_ip_csum, rx_udp_csum;
    reg        rx_err;

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_pos    <= 0;
            rx_frames <= 0;
        end else if (rx_tvalid) begin
            if (rx_pos == 24) rx_ip_csum[15:8]  <= rx_tdata;
            if (rx_pos == 25) rx_ip_csum[7:0]   <= rx_tdata;
            if (rx_pos == 40) rx_udp_csum[15:8] <= rx_tdata;
            if (rx_pos == 41) rx_udp_csum[7:0]  <= rx_tdata;
            if (rx_tlast) begin
                rx_err    <= rx_terror;
                rx_frames <= rx_frames + 1;
                rx_pos    <= 0;
            end else begin
                rx_pos <= rx_pos + 1;
            end
        end
    end

    task run_frame;
        input [31:0] ctrl;
        integer n0;
        begin
            axi_write(8'h04, ctrl);
            n0 = rx_frames;
            send_frame;
            // 60 bytes + FCS + preamble at 25 MHz MII nibbles, plus
            // store-and-forward: well under 20 us.
            repeat (4000) @(posedge clk);
            check32("frames received", rx_frames - n0, 1);
        end
    endtask

    reg [31:0] rd;

    initial begin
        pass_cnt = 0; fail_cnt = 0;
        rst_n = 0;
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arvalid = 0; rready = 0;
        tx_tdata = 0; tx_tvalid = 0; tx_tlast = 0;
        #100 rst_n = 1;
        #100;

        // CTRL bits: [0] tx_en [1] rx_en [2] promisc [5] full_duplex
        //            [7] tx_csum_off [9] rx_csum_off
        axi_write(8'h04, 32'h0000_02A7);
        axi_read(8'h04, rd);
        check32("CTRL readback with [9]", rd, 32'h0000_02A7);

        $display("--- A: TX insert + RX verify ---");
        run_frame(32'h0000_02A7);
        check32("A ip csum",  {16'd0, rx_ip_csum},  32'h0000_A440);
        check32("A udp csum", {16'd0, rx_udp_csum}, 32'h0000_4EF6);
        check32("A terror",   {31'd0, rx_err},      32'd0);
        axi_read(8'h80, rd);
        check32("A RX_ERR_CSUM", rd, 32'd0);

        $display("--- B: wrong checksums, RX verify on ---");
        run_frame(32'h0000_0227);
        check32("B ip csum",  {16'd0, rx_ip_csum},  32'h0000_DEAD);
        check32("B udp csum", {16'd0, rx_udp_csum}, 32'h0000_BEEF);
        check32("B terror",   {31'd0, rx_err},      32'd1);
        axi_read(8'h80, rd);
        check32("B RX_ERR_CSUM", rd, 32'd1);
        axi_read(8'h38, rd);
        check32("B RX_ERR", rd, 32'd1);

        $display("--- C: wrong checksums, RX verify off ---");
        run_frame(32'h0000_0027);
        check32("C terror",   {31'd0, rx_err}, 32'd0);
        axi_read(8'h80, rd);
        check32("C RX_ERR_CSUM", rd, 32'd1);

        $display("--- D: write clears RX_ERR_CSUM ---");
        axi_write(8'h80, 32'd0);
        axi_read(8'h80, rd);
        check32("D RX_ERR_CSUM", rd, 32'd0);

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
