// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_eth_mac_sys_max_frame.v - RX frame-size limits through eth_mac_sys
// eth_mac_sys built with a non-default MAX_FRAME (2000), GMII pins looped back.
//   - jumbo_en=1: a MAX_FRAME (2000-byte) frame is accepted and a 2001-byte
//     one is delivered with terror and counted in RX_ERR_OVERSIZE. eth_mac_rx
//     used to keep its own 9018 limit whatever MAX_FRAME was.
//   - jumbo_en=0: an 802.1Q-tagged 1522-byte frame is accepted and an
//     untagged one of the same size is oversize.
// Frame sizes are wire bytes after the SFD, FCS included, as MAX_FRAME is.
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_eth_mac_sys_max_frame;

    localparam MAX_FRAME = 2000;

    reg sys_clk = 0;
    reg clk_125 = 0;
    reg rx_clk  = 0;
    reg rst_n;

    always #4 sys_clk = ~sys_clk;
    always #4 clk_125 = ~clk_125;
    initial begin
        #2;
        forever #4 rx_clk = ~rx_clk;
    end

    // ---- AXI4-Lite ----
    reg  [7:0]  awaddr;  reg awvalid;  wire awready;
    reg  [31:0] wdata;   reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp;   wire bvalid;  reg bready;
    reg  [7:0]  araddr;  reg arvalid;  wire arready;
    wire [31:0] rdata;   wire [1:0] rresp; wire rvalid; reg rready;

    // ---- AXI4-Stream ----
    reg  [7:0]  tx_tdata;
    reg         tx_tvalid;
    wire        tx_tready;
    reg         tx_tlast;
    wire [7:0]  rx_tdata;
    wire        rx_tvalid;
    wire        rx_tlast;
    wire        rx_terror;
    wire        rx_tsof;

    // ---- GMII ----
    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire        gmii_tx_er;
    wire        gmii_txc;
    reg  [7:0]  gmii_rxd;
    reg         gmii_rx_dv;
    reg         gmii_rx_er;

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
        .mii_txd        (),
        .mii_tx_en      (),
        .mii_tx_clk     (1'b0),
        .mii_rxd        (4'd0),
        .mii_rx_dv      (1'b0),
        .mii_rx_er      (1'b0),
        .mii_rx_clk     (1'b0),
        .mii_col        (1'b0),
        .mii_crs        (1'b0),
        .clk_125        (clk_125),
        .clk_125_90     (clk_125),
        .clk_25         (1'b0),
        .clk_2_5        (1'b0),
        .rgmii_txd      (),
        .rgmii_tx_ctl   (),
        .rgmii_txc      (),
        .rgmii_rxd      (4'd0),
        .rgmii_rx_ctl   (1'b0),
        .rgmii_rxc      (1'b0),
        .phy_gmii_txd   (gmii_txd),
        .phy_gmii_tx_en (gmii_tx_en),
        .phy_gmii_tx_er (gmii_tx_er),
        .phy_gmii_txc   (gmii_txc),
        .phy_gmii_rx_clk(rx_clk),
        .phy_gmii_rxd   (gmii_rxd),
        .phy_gmii_rx_dv (gmii_rx_dv),
        .phy_gmii_rx_er (gmii_rx_er),
        .mdc            (),
        .mdio_i         (1'b1),
        .mdio_o         (),
        .mdio_oe        (),
        .cfg_ip_addr    (),
        .irq            ()
    );

    // Stand-in PHY: TX pins back to RX pins on the GTX_CLK rising edge.
    always @(posedge gmii_txc or negedge rst_n) begin
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

    // ---- RX capture: last frame's length and terror ----
    integer rx_len, rx_last_len, rx_frame_cnt;
    reg     rx_last_terror;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            rx_len         <= 0;
            rx_last_len    <= 0;
            rx_frame_cnt   <= 0;
            rx_last_terror <= 1'b0;
        end else if (rx_tvalid) begin
            if (rx_tlast) begin
                rx_last_len    <= rx_len + 1;
                rx_last_terror <= rx_terror;
                rx_len         <= 0;
                rx_frame_cnt   <= rx_frame_cnt + 1;
            end else begin
                rx_len <= rx_len + 1;
            end
        end
    end

    // ---- TX: broadcast frame of `wire_len` bytes on the wire (FCS included),
    // bytes 12-13 = `etype`.
    task send_frame;
        input integer wire_len;
        input [15:0]  etype;
        integer k, total;
        begin
            total = wire_len - 4;
            @(negedge sys_clk);
            for (k = 0; k < total; k = k + 1) begin
                if (k < 6)        tx_tdata = 8'hFF;
                else if (k < 12)  tx_tdata = (k == 6) ? 8'h02 : (k == 11) ? 8'h01 : 8'h00;
                else if (k == 12) tx_tdata = etype[15:8];
                else if (k == 13) tx_tdata = etype[7:0];
                else              tx_tdata = k[7:0];
                tx_tvalid = 1;
                tx_tlast  = (k == total - 1);
                @(negedge sys_clk);
                while (!tx_tready) @(negedge sys_clk);
            end
            tx_tvalid = 0; tx_tlast = 0;
            #100000;
        end
    endtask

    integer pass_cnt, fail_cnt, frames_before;

    // Send one frame and check it arrives whole, with or without terror.
    task check_frame;
        input integer wire_len;
        input [15:0]  etype;
        input         want_terror;
        begin
            frames_before = rx_frame_cnt;
            send_frame(wire_len, etype);
            if (rx_frame_cnt == frames_before + 1 &&
                rx_last_len == wire_len - 4 &&
                rx_last_terror == want_terror) begin
                $display("PASS: %0d-byte frame, type %04h: %0s", wire_len, etype,
                         want_terror ? "oversize (terror)" : "accepted");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0d-byte frame, type %04h: frames +%0d len %0d terror %0d",
                         wire_len, etype, rx_frame_cnt - frames_before,
                         rx_last_len, rx_last_terror);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task check32;
        input [255:0] name;
        input [31:0]  actual;
        input [31:0]  expected;
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

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        rst_n = 0;
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arvalid = 0; rready = 0;
        tx_tdata = 0; tx_tvalid = 0; tx_tlast = 0;
        #100;
        rst_n = 1;
        #200;

        // TX + RX + promisc + jumbo_en (CTRL[6]).
        axi_write(8'h04, 32'h0000_0047);

        // ---- jumbo_en=1: the limit is MAX_FRAME ----
        check_frame(MAX_FRAME,     16'h0800, 1'b0);
        check_frame(MAX_FRAME + 1, 16'h0800, 1'b1);
        axi_read(8'h54, rd_result);
        check32("RX_ERR_OVERSIZE, jumbo", rd_result, 1);

        // ---- jumbo_en=0: 1518, or 1522 with a VLAN tag ----
        axi_write(8'h04, 32'h0000_0007);
        check_frame(1518, 16'h0800, 1'b0);
        check_frame(1522, 16'h8100, 1'b0);
        check_frame(1522, 16'h0800, 1'b1);
        axi_read(8'h54, rd_result);
        check32("RX_ERR_OVERSIZE, std", rd_result, 2);

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
