// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_rgmii_loopback.v - RGMII integration test for eth_mac_sys
// Tests the full RGMII path by instantiating eth_mac_sys with
// PHY_INTERFACE="RGMII" and looping the GMII-level signals inside gmii_cdc
// back to themselves. This exercises: MAC TX → CRC → CDC TX → loopback →
// CDC RX → MAC RX → CRC check → AXI-Stream output.
//
// Note: The DDR behavioral models (ddr_output/ddr_input) are not suitable
// for closed-loop DDR simulation — they don't reproduce real ODDR/IDDR
// timing faithfully. RGMII DDR I/O is verified structurally via synthesis.
// This test verifies the CDC + MAC datapath in RGMII mode.
// =============================================================================
`timescale 1ns / 1ps
`include "version.vh"

module tb_rgmii_loopback;

    // ---- Clocks ----
    reg sys_clk;
    reg clk_125;
    reg rst_n;

    initial sys_clk = 0;
    initial clk_125 = 0;
    always #5 sys_clk = ~sys_clk;   // 100 MHz
    always #4 clk_125 = ~clk_125;   // 125 MHz

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

    // ---- RGMII wires (directly connected, DDR not exercised in sim) ----
    wire [3:0]  rgmii_txd;
    wire        rgmii_tx_ctl;
    wire        rgmii_txc;

    wire irq;

    // We use a standalone gmii_cdc + eth_mac_tx/rx for a clean GMII-level test.
    // The RGMII DDR I/O wrapping is structural-only (verified via synthesis).
    // Here we directly instantiate the RGMII-mode eth_mac_sys and tap internal
    // GMII signals for a media-clock-domain loopback.

    eth_mac_sys #(.PHY_INTERFACE("RGMII")) uut (
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
        // RGMII
        .clk_125        (clk_125),
        .clk_125_90     (clk_125),  // phase shift doesn't matter for sim
        .clk_25         (1'b0),
        .clk_2_5        (1'b0),
        .rgmii_txd      (rgmii_txd),
        .rgmii_tx_ctl   (rgmii_tx_ctl),
        .rgmii_txc      (rgmii_txc),
        .rgmii_rxd      (4'd0),
        .rgmii_rx_ctl   (1'b0),
        .rgmii_rxc      (clk_125),
        // MDIO
        .mdc            (),
        .mdio_i         (1'b1),
        .mdio_o         (),
        .mdio_oe        (),
        .irq            (irq)
    );

    // =========================================================================
    // GMII-level loopback inside gmii_cdc (media_clk domain)
    // Media TX out → 1-cycle register → force into media RX in
    // =========================================================================
    // Tap the media-side TX outputs from gmii_cdc
    wire [7:0] media_txd    = uut.gen_rgmii.u_gmii_cdc.gmii_txd_out;
    wire       media_tx_en  = uut.gen_rgmii.u_gmii_cdc.gmii_tx_en_out;
    wire       media_tx_er  = uut.gen_rgmii.u_gmii_cdc.gmii_tx_er_out;

    // Register the loopback in media_clk (1-cycle PHY delay)
    reg [7:0]  lb_rxd;
    reg        lb_rx_dv;
    reg        lb_rx_er;
    always @(posedge clk_125 or negedge rst_n) begin
        if (!rst_n) begin
            lb_rxd   <= 8'd0;
            lb_rx_dv <= 1'b0;
            lb_rx_er <= 1'b0;
        end else begin
            lb_rxd   <= media_txd;
            lb_rx_dv <= media_tx_en;
            lb_rx_er <= media_tx_er;
        end
    end

    // Force the gmii_cdc RX inputs to loopback data
    // These override the rgmii_if outputs in simulation
    initial begin
        // Wait for reset to deassert
        @(posedge rst_n);
        forever begin
            @(posedge clk_125);
            force uut.gen_rgmii.u_gmii_cdc.gmii_rxd_in  = lb_rxd;
            force uut.gen_rgmii.u_gmii_cdc.gmii_rx_dv_in = lb_rx_dv;
            force uut.gen_rgmii.u_gmii_cdc.gmii_rx_er_in = lb_rx_er;
        end
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
    integer rx_frame_cnt;
    reg     rx_cap;
    always @(posedge sys_clk) begin
        if (!rst_n) begin
            rx_frame_cnt <= 0;
            rx_cap       <= 0;
        end else begin
            if (rx_tvalid)
                rx_cap <= 1;
            else if (rx_cap) begin
                rx_frame_cnt <= rx_frame_cnt + 1;
                rx_cap       <= 0;
            end
        end
    end

    // ---- TX frame injection ----
    task send_frame;
        input integer payload_len;
        integer k, total;
        begin
            total = 14 + payload_len;
            @(negedge sys_clk);
            for (k = 0; k < 6; k = k + 1) begin
                tx_tdata = 8'hFF; tx_tvalid = 1;
                tx_tlast = (k == total - 1) ? 1 : 0;
                @(negedge sys_clk);
                while (!tx_tready) @(negedge sys_clk);
            end
            for (k = 0; k < 6; k = k + 1) begin
                tx_tdata = (k == 0) ? 8'h02 : (k == 5) ? 8'h01 : 8'h00;
                tx_tvalid = 1;
                tx_tlast = (6 + k == total - 1) ? 1 : 0;
                @(negedge sys_clk);
                while (!tx_tready) @(negedge sys_clk);
            end
            tx_tdata = 8'h08; tx_tvalid = 1; tx_tlast = 0;
            @(negedge sys_clk); while (!tx_tready) @(negedge sys_clk);
            tx_tdata = 8'h00; tx_tvalid = 1; tx_tlast = (13 == total - 1) ? 1 : 0;
            @(negedge sys_clk); while (!tx_tready) @(negedge sys_clk);
            for (k = 0; k < payload_len; k = k + 1) begin
                tx_tdata = k[7:0]; tx_tvalid = 1;
                tx_tlast = (14 + k == total - 1) ? 1 : 0;
                @(negedge sys_clk);
                while (!tx_tready) @(negedge sys_clk);
            end
            tx_tvalid = 0; tx_tlast = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_rgmii_loopback.vcd");
        $dumpvars(0, tb_rgmii_loopback);

        pass_cnt = 0;
        fail_cnt = 0;
        rst_n = 0;
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arvalid = 0; rready = 0;
        tx_tdata = 0; tx_tvalid = 0; tx_tlast = 0;
        #100;
        rst_n = 1;
        #200;

        // Test 1: VERSION
        axi_read(8'h00, rd_result);
        check32("VERSION", rd_result,
                {`EMZ_VERSION_MAJOR, `EMZ_VERSION_MINOR, `EMZ_VERSION_ID});

        // Test 2: Enable MAC + promisc
        axi_write(8'h04, 32'h0000_0007);

        // Test 3: Set MAC to broadcast (for loopback acceptance)
        axi_write(8'h0C, 32'hFF_FF_FF_FF);
        axi_write(8'h10, 32'h0000_FF_FF);

        // Test 4: Send a frame via RGMII path
        rx_frame_cnt = 0;
        send_frame(50);

        // Wait for frame to traverse gmii_cdc loopback
        #100000;

        if (rx_frame_cnt >= 1) begin
            $display("PASS: RGMII loopback received %0d frame(s)", rx_frame_cnt);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: RGMII loopback received 0 frames");
            fail_cnt = fail_cnt + 1;
        end

        // Test 5: TX stats
        axi_read(8'h28, rd_result);
        check_nonzero("TX_FRAME_CNT", rd_result);

        // Test 6: RX stats
        axi_read(8'h30, rd_result);
        if (rx_frame_cnt >= 1)
            check_nonzero("RX_FRAME_CNT", rd_result);

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
        #5000000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
