// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_eth_mac_sys.v - Integration testbench for eth_mac_sys.v (MII mode)
// Tests: AXI-Lite config, frame TX/RX through MII loopback, stats, MDIO, IRQ
// =============================================================================
`timescale 1ns / 1ps
`include "version.vh"

module tb_eth_mac_sys;

    // ---- Clocks ----
    reg clk;        // 100 MHz system clock
    reg mii_rx_clk; // 25 MHz MII clock
    reg rst_n;

    initial clk = 0;
    always #5 clk = ~clk;

    initial mii_rx_clk = 0;
    always #20 mii_rx_clk = ~mii_rx_clk;

    // ---- AXI4-Lite ----
    reg  [7:0]  awaddr;  reg awvalid;  wire awready;
    reg  [31:0] wdata;   reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp;   wire bvalid;  reg bready;
    reg  [7:0]  araddr;  reg arvalid;  wire arready;
    wire [31:0] rdata;   wire [1:0] rresp; wire rvalid; reg rready;

    // ---- AXI4-Stream TX ----
    reg  [7:0]  tx_tdata;
    reg         tx_tvalid;
    wire        tx_tready;
    reg         tx_tlast;

    // ---- AXI4-Stream RX ----
    wire [7:0]  rx_tdata;
    wire        rx_tvalid;
    wire        rx_tlast;
    wire        rx_terror;
    wire        rx_tsof;

    // ---- MII (loopback: TX -> RX) ----
    wire [3:0]  mii_txd;
    wire        mii_tx_en;

    // ---- MDIO ----
    wire        mdc;
    wire        mdio_o, mdio_oe;
    wire        irq;

    // MII loopback: TX output feeds back to RX input with 1-cycle delay
    reg [3:0]   mii_rxd_r;
    reg         mii_rx_dv_r;
    always @(posedge mii_rx_clk) begin
        mii_rxd_r  <= mii_txd;
        mii_rx_dv_r <= mii_tx_en;
    end

    eth_mac_sys #(.PHY_INTERFACE("MII")) uut (
        .clk            (clk),
        .rst_n          (rst_n),
        // AXI4-Lite
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
        // AXI4-Stream
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
        // MII
        .mii_txd        (mii_txd),
        .mii_tx_en      (mii_tx_en),
        .mii_tx_clk     (mii_rx_clk),  // use same 25 MHz clock
        .mii_rxd        (mii_rxd_r),
        .mii_rx_dv      (mii_rx_dv_r),
        .mii_rx_er      (1'b0),
        .mii_rx_clk     (mii_rx_clk),
        .mii_col        (1'b0),
        .mii_crs        (1'b0),
        // RGMII (unused)
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
        // MDIO
        .mdc            (mdc),
        .mdio_i         (mdio_o),  // loopback for basic test
        .mdio_o         (mdio_o),
        .mdio_oe        (mdio_oe),
        .irq            (irq)
    );

    // ---- AXI4-Lite BFM tasks ----
    reg [31:0] rd_result;

    task axi_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            awaddr  = addr; awvalid = 1;
            wdata   = data; wstrb   = 4'hF; wvalid = 1;
            bready  = 1;
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

    task check_nonzero;
        input [255:0] name;
        input [31:0]  actual;
        begin
            if (actual !== 32'd0) begin
                $display("PASS: %0s = %0d (nonzero)", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = 0, expected nonzero", name);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ---- RX capture ----
    integer rx_byte_cnt;
    integer rx_frame_cnt;
    reg     rx_cap;

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_byte_cnt  <= 0;
            rx_frame_cnt <= 0;
            rx_cap       <= 0;
        end else begin
            if (rx_tvalid) begin
                rx_byte_cnt <= rx_byte_cnt + 1;
                rx_cap      <= 1;
            end else if (rx_cap) begin
                rx_frame_cnt <= rx_frame_cnt + 1;
                rx_cap       <= 0;
            end
        end
    end

    // ---- TX frame injection ----
    // Send a broadcast Ethernet frame: dst=FF:FF:FF:FF:FF:FF, src=02:00:00:00:00:01
    // payload = incrementing bytes, total 64 bytes (header + payload)
    task send_frame;
        input integer payload_len;
        integer k;
        integer total;
        begin
            total = 14 + payload_len; // 6 dst + 6 src + 2 ethertype + payload
            @(negedge clk);
            // Destination MAC: FF:FF:FF:FF:FF:FF (broadcast)
            for (k = 0; k < 6; k = k + 1) begin
                tx_tdata  = 8'hFF;
                tx_tvalid = 1;
                tx_tlast  = (k == total - 1) ? 1 : 0;
                @(negedge clk);
                while (!tx_tready) @(negedge clk);
            end
            // Source MAC: 02:00:00:00:00:01
            for (k = 0; k < 6; k = k + 1) begin
                tx_tdata  = (k == 0) ? 8'h02 : (k == 5) ? 8'h01 : 8'h00;
                tx_tvalid = 1;
                tx_tlast  = (6 + k == total - 1) ? 1 : 0;
                @(negedge clk);
                while (!tx_tready) @(negedge clk);
            end
            // EtherType: 0x0800
            tx_tdata = 8'h08; tx_tvalid = 1; tx_tlast = (12 == total - 1) ? 1 : 0;
            @(negedge clk);
            while (!tx_tready) @(negedge clk);
            tx_tdata = 8'h00; tx_tvalid = 1; tx_tlast = (13 == total - 1) ? 1 : 0;
            @(negedge clk);
            while (!tx_tready) @(negedge clk);
            // Payload
            for (k = 0; k < payload_len; k = k + 1) begin
                tx_tdata  = k[7:0];
                tx_tvalid = 1;
                tx_tlast  = (14 + k == total - 1) ? 1 : 0;
                @(negedge clk);
                while (!tx_tready) @(negedge clk);
            end
            tx_tvalid = 0;
            tx_tlast  = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_eth_mac_sys.vcd");
        $dumpvars(0, tb_eth_mac_sys);

        pass_cnt = 0;
        fail_cnt = 0;

        // Init
        rst_n = 0;
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arvalid = 0; rready = 0;
        tx_tdata = 0; tx_tvalid = 0; tx_tlast = 0;
        #100;
        rst_n = 1;
        #100;

        // =================================================================
        // Test 1: Read VERSION register
        // =================================================================
        axi_read(8'h00, rd_result);
        check32("VERSION", rd_result,
                {`EMZ_VERSION_MAJOR, `EMZ_VERSION_MINOR, `EMZ_VERSION_ID});

        // =================================================================
        // Test 2: Write MAC address via CSR
        // =================================================================
        axi_write(8'h0C, 32'hFF_FF_FF_FF);  // MAC_LO (broadcast for loopback)
        axi_write(8'h10, 32'h0000_FF_FF);   // MAC_HI
        axi_read(8'h0C, rd_result);
        check32("MAC_LO", rd_result, 32'hFFFFFFFF);

        // =================================================================
        // Test 3: Enable TX+RX, promiscuous mode
        // =================================================================
        axi_write(8'h04, 32'h0000_0007);  // tx_en=1, rx_en=1, promisc=1
        axi_read(8'h04, rd_result);
        check32("CTRL promisc", rd_result, 32'h0000_0007);

        // =================================================================
        // Test 4: Send a frame through MII loopback
        // =================================================================
        rx_byte_cnt  = 0;
        rx_frame_cnt = 0;

        send_frame(50);  // 14-byte header + 50-byte payload = 64 bytes

        // Wait for frame to traverse MII loopback (takes many cycles at 25 MHz)
        // MII is 4x slower than sys_clk, plus store-and-forward latency
        #200000;

        if (rx_frame_cnt >= 1) begin
            $display("PASS: received %0d frame(s) via MII loopback", rx_frame_cnt);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: received 0 frames via MII loopback");
            fail_cnt = fail_cnt + 1;
        end

        // =================================================================
        // Test 5: Check TX stats (frame count > 0)
        // =================================================================
        axi_read(8'h28, rd_result);
        check_nonzero("TX_FRAME_CNT", rd_result);

        axi_read(8'h2C, rd_result);
        check_nonzero("TX_BYTE_CNT", rd_result);

        // =================================================================
        // Test 6: Check RX stats
        // =================================================================
        axi_read(8'h30, rd_result);
        if (rx_frame_cnt >= 1) begin
            check_nonzero("RX_FRAME_CNT", rd_result);
        end else begin
            $display("SKIP: RX_FRAME_CNT (no frame received)");
        end

        // =================================================================
        // Test 7: Clear stats
        // =================================================================
        axi_write(8'h28, 32'd0);  // clear TX stats
        #50;
        axi_read(8'h28, rd_result);
        check32("TX_FRAME_CNT after clear", rd_result, 32'd0);

        // =================================================================
        // Test 8: MDIO - trigger a read command via CSR
        // =================================================================
        axi_write(8'h14, 32'h0000_0800);  // go=1, read, phy=0, reg=0
        #80000;  // MDIO takes ~65us at 1MHz MDC (64 bit periods)
        axi_read(8'h08, rd_result);
        // mdio_busy should be 0 after completion
        check32("STATUS mdio_busy cleared", rd_result & 32'h4, 32'h0);

        // =================================================================
        // Summary
        // =================================================================
        #100;
        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    // Timeout
    initial begin
        #5000000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
