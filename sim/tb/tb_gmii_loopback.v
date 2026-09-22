// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_gmii_loopback.v - GMII integration test for eth_mac_sys
// Instantiates eth_mac_sys with PHY_INTERFACE="GMII" and loops the GMII TX
// pins back to the GMII RX pins through a one-cycle register (a stand-in for
// the PHY). Exercises: MAC TX -> CRC -> gmii_cdc TX -> gmii_if TX pins ->
// loopback -> gmii_if RX pins -> gmii_cdc RX -> MAC RX -> CRC check -> AXIS.
//
// Unlike tb_rgmii_loopback, this closes the loop at the actual module pins
// rather than forcing internal gmii_cdc nets: GMII is single-data-rate, so no
// DDR behavioural model sits in the path and the full pin-level datapath
// (gmii_if included) is covered.
//
// Checks frame count, exact received length with the FCS stripped, header and
// payload content, and zero CRC errors, across a small, a standard-MTU and a
// jumbo frame; that clearing jumbo_en flags the oversize frame; and that
// GTX_CLK toggles with its rising edge inside the TXD data window to the
// IEEE 802.3 GMII setup/hold budget.
// =============================================================================
`timescale 1ns / 1ps
`include "version.vh"

module tb_gmii_loopback;

    localparam MAX_FRAME = 9018;

    // ---- Clocks ----
    reg sys_clk;
    reg clk_125;
    reg rx_clk;
    reg rst_n;

    initial sys_clk = 0;
    initial clk_125 = 0;
    always #5 sys_clk = ~sys_clk;   // 100 MHz
    always #4 clk_125 = ~clk_125;   // 125 MHz

    // PHY-sourced RX clock: same nominal rate, deliberately offset 2 ns from
    // clk_125 so the RX capture path cannot pass merely because the testbench
    // handed the DUT the same net for both domains.
    initial begin
        rx_clk = 0;
        #2;
        forever #4 rx_clk = ~rx_clk;
    end

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

    // ---- GMII pins ----
    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire        gmii_tx_er;
    wire        gmii_gtx_clk;

    reg  [7:0]  gmii_rxd;
    reg         gmii_rx_dv;
    reg         gmii_rx_er;

    wire irq;

    eth_mac_sys #(
        .PHY_INTERFACE ("GMII"),
        .MAX_FRAME     (MAX_FRAME)
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
        // MII unused
        .mii_txd        (),
        .mii_tx_en      (),
        .mii_tx_clk     (1'b0),
        .mii_rxd        (4'd0),
        .mii_rx_dv      (1'b0),
        .mii_rx_er      (1'b0),
        .mii_rx_clk     (1'b0),
        .mii_col        (1'b0),
        .mii_crs        (1'b0),
        // Clock group (clk_25 / clk_2_5 unused on the GMII branch)
        .clk_125        (clk_125),
        .clk_125_90     (clk_125),  // unused: the GMII branch forwards GTX_CLK from clk_125
        .clk_25         (1'b0),
        .clk_2_5        (1'b0),
        // RGMII unused
        .rgmii_txd      (),
        .rgmii_tx_ctl   (),
        .rgmii_txc      (),
        .rgmii_rxd      (4'd0),
        .rgmii_rx_ctl   (1'b0),
        .rgmii_rxc      (1'b0),
        // GMII
        .phy_gmii_txd     (gmii_txd),
        .phy_gmii_tx_en   (gmii_tx_en),
        .phy_gmii_tx_er   (gmii_tx_er),
        .phy_gmii_gtx_clk (gmii_gtx_clk),
        .phy_gmii_rx_clk  (rx_clk),
        .phy_gmii_rxd     (gmii_rxd),
        .phy_gmii_rx_dv   (gmii_rx_dv),
        .phy_gmii_rx_er   (gmii_rx_er),
        // MDIO
        .mdc            (),
        .mdio_i         (1'b1),
        .mdio_o         (),
        .mdio_oe        (),
        .cfg_ip_addr    (),
        .irq            (irq)
    );

    // =========================================================================
    // Pin-level GMII loopback: a stand-in PHY
    // =========================================================================
    // The PHY captures TXD/TX_EN/TX_ER on the RISING EDGE OF GTX_CLK, exactly
    // as IEEE 802.3 Clause 35 specifies. Sampling on clk_125 instead would let
    // a stuck, mis-phased or wrong-frequency GTX_CLK still carry data through
    // the loopback and pass every datapath check in this file.
    always @(posedge gmii_gtx_clk or negedge rst_n) begin
        if (!rst_n) begin
            gmii_rxd   <= 8'd0;
            gmii_rx_dv <= 1'b0;
            gmii_rx_er <= 1'b0;
        end else begin
            gmii_rxd   <= gmii_txd;
            gmii_rx_dv <= gmii_tx_en;
            gmii_rx_er <= gmii_tx_er;
        end
    end

    // =========================================================================
    // GTX_CLK phase monitor
    // =========================================================================
    // TXD is launched on posedge clk_125, so the PHY's sampling edge (posedge
    // gmii_gtx_clk) must land inside that 8 ns data window with at least 2.5 ns
    // setup and 0.5 ns hold - the IEEE 802.3 GMII TX requirement at the PHY
    // pins. Measuring the offset directly catches a GTX_CLK that is stuck,
    // edge-aligned with the data, or forwarded from the wrong phase.
    real    last_txclk_edge;
    real    gtx_offset;
    integer gtx_edges;
    integer gtx_phase_viol;

    initial begin
        last_txclk_edge = -1000.0;
        gtx_edges       = 0;
        gtx_phase_viol  = 0;
    end

    always @(posedge clk_125) last_txclk_edge = $realtime;

    always @(posedge gmii_gtx_clk) begin
        if (rst_n) begin
            gtx_edges = gtx_edges + 1;
            #0.1;   // settle past any same-timestamp delta ordering
            gtx_offset = ($realtime - 0.1) - last_txclk_edge;
            if ((gtx_offset < 2.5) || (gtx_offset > 7.5))
                gtx_phase_viol = gtx_phase_viol + 1;
        end
    end

    // -------------------------------------------------------------------------
    // GTX_CLK integrity: continuity, frequency and duty cycle
    // -------------------------------------------------------------------------
    // The phase check alone cannot catch a clock that runs at the wrong rate,
    // stops part-way, or has a legal-phase but illegal-width pulse. Count
    // clk_125 edges over the same window and require GTX_CLK to keep up, and
    // check both pulse widths against Clause 35's 35%-75% duty allowance
    // (2.8 ns to 6.0 ns of the 8 ns period).
    integer clk125_edges;
    real    gtx_last_rise;
    real    gtx_last_fall;
    integer gtx_width_viol;

    initial begin
        clk125_edges   = 0;
        gtx_last_rise  = -1000.0;
        gtx_last_fall  = -1000.0;
        gtx_width_viol = 0;
    end

    always @(posedge clk_125) if (rst_n) clk125_edges = clk125_edges + 1;

    always @(posedge gmii_gtx_clk) begin
        if (rst_n && (gtx_last_fall > 0.0)) begin
            if ((($realtime - gtx_last_fall) < 2.8) ||
                (($realtime - gtx_last_fall) > 6.0))
                gtx_width_viol = gtx_width_viol + 1;   // low time out of range
        end
        gtx_last_rise = $realtime;
    end

    always @(negedge gmii_gtx_clk) begin
        if (rst_n && (gtx_last_rise > 0.0)) begin
            if ((($realtime - gtx_last_rise) < 2.8) ||
                (($realtime - gtx_last_rise) > 6.0))
                gtx_width_viol = gtx_width_viol + 1;   // high time out of range
        end
        gtx_last_fall = $realtime;
    end

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
    // RX capture: bytes of the most recent frame, frame count, error count
    // =========================================================================
    reg  [7:0] rx_buf [0:MAX_FRAME-1];
    integer    rx_len;        // length of the frame currently being captured
    integer    rx_last_len;   // length of the last completed frame
    integer    rx_frame_cnt;
    integer    rx_err_cnt;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            rx_len       <= 0;
            rx_last_len  <= 0;
            rx_frame_cnt <= 0;
            rx_err_cnt   <= 0;
        end else if (rx_tvalid) begin
            if (rx_len < MAX_FRAME)
                rx_buf[rx_len] <= rx_tdata;
            if (rx_terror)
                rx_err_cnt <= rx_err_cnt + 1;
            if (rx_tlast) begin
                rx_last_len  <= rx_len + 1;
                rx_len       <= 0;
                rx_frame_cnt <= rx_frame_cnt + 1;
            end else begin
                rx_len <= rx_len + 1;
            end
        end
    end

    // =========================================================================
    // TX frame injection: 6B broadcast DA, 6B SA, 2B ethertype, payload
    // Payload byte k = k[7:0], so the receiver can verify content exactly.
    // =========================================================================
    task send_frame;
        input integer payload_len;
        integer k, total;
        begin
            total = 14 + payload_len;
            @(negedge sys_clk);
            for (k = 0; k < total; k = k + 1) begin
                if (k < 6)
                    tx_tdata = 8'hFF;                                  // DA broadcast
                else if (k < 12)
                    tx_tdata = (k == 6) ? 8'h02 : (k == 11) ? 8'h01 : 8'h00;  // SA
                else if (k == 12)
                    tx_tdata = 8'h08;                                  // ethertype hi
                else if (k == 13)
                    tx_tdata = 8'h00;                                  // ethertype lo
                else
                    tx_tdata = (k - 14);                               // payload
                tx_tvalid = 1;
                tx_tlast  = (k == total - 1);
                @(negedge sys_clk);
                while (!tx_tready) @(negedge sys_clk);
            end
            tx_tvalid = 0; tx_tlast = 0;
        end
    endtask

    // Verify the captured frame against what send_frame(payload_len) sent.
    // The MAC strips the 4-byte FCS, so the received length equals the
    // transmitted length for any frame at or above the 60-byte minimum.
    task check_frame;
        input [255:0] name;
        input integer payload_len;
        integer k, total, bad;
        begin
            total = 14 + payload_len;
            check_int({name, " len"}, rx_last_len, total);
            bad = 0;
            // Header must survive intact too: promiscuous mode is on, so a
            // corrupted DA/SA/EtherType would otherwise still be accepted.
            for (k = 0; k < 6; k = k + 1)
                if (rx_buf[k] !== 8'hFF) bad = bad + 1;
            for (k = 6; k < 12; k = k + 1)
                if (rx_buf[k] !== ((k == 6) ? 8'h02 : (k == 11) ? 8'h01 : 8'h00))
                    bad = bad + 1;
            if (rx_buf[12] !== 8'h08) bad = bad + 1;
            if (rx_buf[13] !== 8'h00) bad = bad + 1;
            for (k = 14; k < total; k = k + 1) begin
                if (rx_buf[k] !== ((k - 14) & 8'hFF))
                    bad = bad + 1;
            end
            if (bad == 0) begin
                $display("PASS: %0s header + payload (%0d bytes) matches", name, payload_len);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s header/payload has %0d mismatched bytes", name, bad);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_gmii_loopback.vcd");
        $dumpvars(0, tb_gmii_loopback);

        pass_cnt = 0;
        fail_cnt = 0;
        rst_n = 0;
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arvalid = 0; rready = 0;
        tx_tdata = 0; tx_tvalid = 0; tx_tlast = 0;
        #100;
        rst_n = 1;
        #200;

        // Test 1: VERSION register reads back through the GMII-mode build
        axi_read(8'h00, rd_result);
        check32("VERSION", rd_result,
                {`EMZ_VERSION_MAJOR, `EMZ_VERSION_MINOR, `EMZ_VERSION_ID});

        // Test 2: enable TX + RX + promisc + jumbo, and accept broadcast.
        // CONFIG[2:0] = tx_en/rx_en/promisc, CONFIG[6] = jumbo_en.
        axi_write(8'h04, 32'h0000_0047);
        axi_write(8'h0C, 32'hFF_FF_FF_FF);
        axi_write(8'h10, 32'h0000_FF_FF);

        // Test 3: small frame (64 bytes on the wire, no padding needed)
        send_frame(50);
        #200000;
        check_int("small frame count", rx_frame_cnt, 1);
        check_frame("small", 50);

        // Test 4: standard MTU frame
        send_frame(1500);
        #2000000;
        check_int("mtu frame count", rx_frame_cnt, 2);
        check_frame("mtu", 1500);

        // Test 5: jumbo frame - proves the GMII branch inherits gmii_cdc's
        // jumbo capability, unlike the standard-MTU-only MII path
        send_frame(4000);
        #5000000;
        check_int("jumbo frame count", rx_frame_cnt, 3);
        check_frame("jumbo", 4000);

        // Test 6: no CRC errors anywhere in the loopback
        check_int("rx error beats", rx_err_cnt, 0);

        // Test 7: stats counters advanced
        axi_read(8'h28, rd_result);
        check32("TX_FRAME_CNT", rd_result, 32'd3);
        axi_read(8'h30, rd_result);
        check32("RX_FRAME_CNT", rd_result, 32'd3);

        // Test 8: GTX_CLK is alive and correctly phased. Without this, a stuck
        // or edge-aligned GTX_CLK passes every other check in this file.
        // Edge-for-edge with clk_125: catches a stopped, halved or doubled
        // GTX_CLK, which a bare "did it toggle at all" check would not.
        if ((gtx_edges <= clk125_edges + 2) && (gtx_edges + 2 >= clk125_edges)
            && (clk125_edges > 1000)) begin
            $display("PASS: GTX_CLK tracks clk_125 (%0d vs %0d rising edges)",
                     gtx_edges, clk125_edges);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: GTX_CLK %0d rising edges vs clk_125 %0d - stuck, halted or wrong rate",
                     gtx_edges, clk125_edges);
            fail_cnt = fail_cnt + 1;
        end
        check_int("GTX_CLK phase violations", gtx_phase_viol, 0);
        check_int("GTX_CLK pulse-width violations", gtx_width_viol, 0);

        // Test 9: the oversize gate works on the GMII path. Clear jumbo_en and
        // resend the same jumbo frame - it must now be delivered with terror
        // and counted in RX_ERR_OVERSIZE rather than accepted silently.
        axi_read(8'h54, rd_result);
        check32("RX_ERR_OVERSIZE before", rd_result, 32'd0);

        axi_write(8'h04, 32'h0000_0007);   // jumbo_en = 0
        send_frame(4000);
        #5000000;

        if (rx_err_cnt > 0) begin
            $display("PASS: oversize frame flagged with terror (%0d beat(s))", rx_err_cnt);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: oversize frame not flagged with terror");
            fail_cnt = fail_cnt + 1;
        end

        axi_read(8'h54, rd_result);
        if (rd_result != 32'd0) begin
            $display("PASS: RX_ERR_OVERSIZE = %0d", rd_result);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: RX_ERR_OVERSIZE = 0, expected nonzero");
            fail_cnt = fail_cnt + 1;
        end

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
        #50000000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
