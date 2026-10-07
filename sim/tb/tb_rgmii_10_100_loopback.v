// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_rgmii_10_100_loopback.v - RGMII 10/100 pin-level loopback for eth_mac_sys
// Instantiates eth_mac_sys with PHY_INTERFACE="RGMII" at 100M (default) or
// 10M (`define RGMII_10M) and loops the RGMII TX pins back to the RX pins
// through a stand-in PHY: the same delay on TXC and on the data, so RXC is
// the forwarded TXC and RX samples where a PHY would. Exercises: MAC TX ->
// gmii_cdc pacer -> rgmii_if nibble serializer -> pins -> rgmii_if nibble
// pairing -> gmii_cdc RX -> MAC RX -> CRC check -> AXIS. Also checks the TXC
// period and duty cycle and that each TXC edge is at least 8 ns from any
// TXD / TX_CTL change.
//
// At 10/100 a byte spans two RXC cycles. This test guards three bugs:
//   - rgmii_if pulsed gmii_rx_dv once per byte, so gmii_cdc closed a frame
//     after every byte (each byte arrived as its own frame).
//   - rgmii_if sent TXD[3:0] in both cycles of a byte and never TXD[7:4].
//   - gmii_cdc left only 64 ns of TX_EN low between paced frames, too short
//     for a 2.5 MHz TXC to see, so back-to-back frames merged.
// Frames carry distinct payload seeds, so a merged, split or truncated frame
// cannot pass the length and content checks.
// =============================================================================
`timescale 1ns / 1ps
`include "version.vh"

module tb_rgmii_10_100_loopback;

    localparam MAX_FRAME = 9018;

`ifdef RGMII_10M
    localparam [1:0] SPEED    = 2'b10;
    localparam       HALF_PER = 200;    // 2.5 MHz
    localparam       PIN_DLY  = 100;
    localparam       BYTE_NS  = 800;
`else
    localparam [1:0] SPEED    = 2'b01;
    localparam       HALF_PER = 20;     // 25 MHz
    localparam       PIN_DLY  = 10;
    localparam       BYTE_NS  = 80;
`endif

    // ---- Clocks: all edges aligned at t=0, as from one MMCM. TXC is made
    // from clk_125 (HALF_PER is its expected half period). ----
    reg sys_clk, clk_125, rst_n;
    initial begin sys_clk = 0; clk_125 = 0; end
    always #5        sys_clk  = ~sys_clk;    // 100 MHz
    always #4        clk_125  = ~clk_125;    // 125 MHz

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

    // ---- RGMII pins ----
    wire [3:0]  rgmii_txd;
    wire        rgmii_tx_ctl;
    wire        rgmii_txc;
    wire [3:0]  rgmii_rxd;
    wire        rgmii_rx_ctl;

    wire        rgmii_rxc;

    // The pins as a PHY sees them: the behavioral DDR model can glitch for
    // zero time at a clock edge, which the 10 ps inertial delay drops.
    wire [3:0]  txd_s;
    wire        ctl_s, txc_s;
    assign #0.01 txd_s = rgmii_txd;
    assign #0.01 ctl_s = rgmii_tx_ctl;
    assign #0.01 txc_s = rgmii_txc;

    // Stand-in PHY: TXC and the data come back with the same PIN_DLY, so RX
    // samples on the forwarded TXC edges, mid-way through each nibble.
    assign #PIN_DLY rgmii_rxd    = txd_s;
    assign #PIN_DLY rgmii_rx_ctl = ctl_s;
    assign #PIN_DLY rgmii_rxc    = txc_s;

    wire irq;

    eth_mac_sys #(
        .PHY_INTERFACE ("RGMII"),
        .MAX_FRAME     (MAX_FRAME),
        .RGMII_SPEEDS  ("10_100")    // 10/100 only: a 100 MHz clk is enough
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
        // Clock group
        .clk_125        (clk_125),
        .clk_125_90     (1'b0),     // unused for RGMII_SPEEDS="10_100"
        .clk_25         (1'b0),     // unused
        .clk_2_5        (1'b0),     // unused
        // RGMII
        .rgmii_txd      (rgmii_txd),
        .rgmii_tx_ctl   (rgmii_tx_ctl),
        .rgmii_txc      (rgmii_txc),
        .rgmii_rxd      (rgmii_rxd),
        .rgmii_rx_ctl   (rgmii_rx_ctl),
        .rgmii_rxc      (rgmii_rxc),
        // GMII unused
        .phy_gmii_txd     (),
        .phy_gmii_tx_en   (),
        .phy_gmii_tx_er   (),
        .phy_gmii_txc     (),
        .phy_gmii_rx_clk  (1'b0),
        .phy_gmii_rxd     (8'd0),
        .phy_gmii_rx_dv   (1'b0),
        .phy_gmii_rx_er   (1'b0),
        // MDIO
        .mdc            (),
        .mdio_i         (1'b1),
        .mdio_o         (),
        .mdio_oe        (),
        .cfg_ip_addr    (),
        .irq            (irq)
    );

    // =========================================================================
    // Wire monitor: shortest TX_CTL-low gap between frames, in TXC cycles
    // =========================================================================
    integer gap_cycles, min_gap, tx_bursts;
    reg     ctl_d;
    initial begin gap_cycles = 0; min_gap = 1000000; tx_bursts = 0; ctl_d = 0; end
    always @(posedge txc_s) begin
        if (rst_n) begin
            if (ctl_s) begin
                if (!ctl_d) begin
                    if (tx_bursts > 0 && gap_cycles < min_gap)
                        min_gap = gap_cycles;
                    tx_bursts = tx_bursts + 1;
                end
                gap_cycles = 0;
            end else begin
                gap_cycles = gap_cycles + 1;
            end
            ctl_d = ctl_s;
        end
    end

    // =========================================================================
    // TXC timing: period, high time, and the distance from each TXC edge to
    // the nearest TXD / TX_CTL change (setup and hold at the PHY)
    // =========================================================================
    // Armed once cfg_speed has reached the media domain (mon_on), so the
    // switch from the reset speed is not counted.
    reg      mon_on;
    realtime t_rise, t_edge, t_data, min_margin;
    integer  txc_rises, bad_period, bad_high;
    initial begin
        mon_on = 0;
        t_rise = 0; t_edge = 0; t_data = 0; min_margin = 1.0e9;
        txc_rises = 0; bad_period = 0; bad_high = 0;
    end
    function off_by;   // |a - b| above 1 ps
        input real a, b;
        off_by = (a - b > 0.001) || (b - a > 0.001);
    endfunction
    always @(txd_s or ctl_s) begin
        if (mon_on && ($realtime - t_edge) < min_margin)
            min_margin = $realtime - t_edge;
        t_data = $realtime;
    end
    always @(posedge txc_s) begin
        if (mon_on) begin
            if (($realtime - t_data) < min_margin)
                min_margin = $realtime - t_data;
            if (txc_rises > 0 && off_by($realtime - t_rise, 2.0 * HALF_PER))
                bad_period = bad_period + 1;
            txc_rises = txc_rises + 1;
        end
        t_rise = $realtime;
        t_edge = $realtime;
    end
    always @(negedge txc_s) begin
        if (mon_on && txc_rises > 0) begin
            if (($realtime - t_data) < min_margin)
                min_margin = $realtime - t_data;
            if (off_by($realtime - t_rise, HALF_PER))
                bad_high = bad_high + 1;
        end
        t_edge = $realtime;
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
    // RX capture: per-frame length and content check as frames arrive
    // =========================================================================
    // Frame n is expected to have payload length exp_len[n] and payload byte k
    // equal to (exp_seed[n] + k) & 8'hFF.
    integer exp_len  [0:15];
    integer exp_seed [0:15];
    integer rx_frame_cnt, rx_err_cnt, rx_bad_frames, rx_pos, rx_bad_bytes;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            rx_frame_cnt  <= 0;
            rx_err_cnt    <= 0;
            rx_bad_frames <= 0;
            rx_pos        = 0;
            rx_bad_bytes  = 0;
        end else if (rx_tvalid) begin
            if (rx_terror) rx_err_cnt <= rx_err_cnt + 1;
            if (rx_pos < 6) begin
                if (rx_tdata !== 8'hFF) rx_bad_bytes = rx_bad_bytes + 1;
            end else if (rx_pos < 12) begin
                if (rx_tdata !== ((rx_pos == 6) ? 8'h02 : (rx_pos == 11) ? 8'h01 : 8'h00))
                    rx_bad_bytes = rx_bad_bytes + 1;
            end else if (rx_pos == 12) begin
                if (rx_tdata !== 8'h08) rx_bad_bytes = rx_bad_bytes + 1;
            end else if (rx_pos == 13) begin
                if (rx_tdata !== 8'h00) rx_bad_bytes = rx_bad_bytes + 1;
            end else begin
                if (rx_tdata !== ((exp_seed[rx_frame_cnt] + rx_pos - 14) & 8'hFF))
                    rx_bad_bytes = rx_bad_bytes + 1;
            end
            if (rx_tlast) begin
                if (rx_bad_bytes != 0 || rx_pos + 1 != 14 + exp_len[rx_frame_cnt]) begin
                    $display("  frame %0d: len %0d (expected %0d), %0d bad bytes",
                             rx_frame_cnt, rx_pos + 1, 14 + exp_len[rx_frame_cnt],
                             rx_bad_bytes);
                    rx_bad_frames <= rx_bad_frames + 1;
                end
                rx_frame_cnt <= rx_frame_cnt + 1;
                rx_pos        = 0;
                rx_bad_bytes  = 0;
            end else begin
                rx_pos = rx_pos + 1;
            end
        end
    end

    // =========================================================================
    // TX frame injection: broadcast DA, fixed SA, EtherType 0x0800, payload
    // byte k = seed + k.
    // =========================================================================
    integer tx_frames;

    task send_frame;
        input integer payload_len;
        input integer seed;
        integer k, total;
        begin
            exp_len[tx_frames]  = payload_len;
            exp_seed[tx_frames] = seed;
            tx_frames = tx_frames + 1;
            total = 14 + payload_len;
            @(negedge sys_clk);
            for (k = 0; k < total; k = k + 1) begin
                if (k < 6)
                    tx_tdata = 8'hFF;
                else if (k < 12)
                    tx_tdata = (k == 6) ? 8'h02 : (k == 11) ? 8'h01 : 8'h00;
                else if (k == 12)
                    tx_tdata = 8'h08;
                else if (k == 13)
                    tx_tdata = 8'h00;
                else
                    tx_tdata = (seed + k - 14) & 8'hFF;
                tx_tvalid = 1;
                tx_tlast  = (k == total - 1);
                @(negedge sys_clk);
                while (!tx_tready) @(negedge sys_clk);
            end
            tx_tvalid = 0; tx_tlast = 0;
        end
    endtask

    // Wait until n frames have arrived, or give up after timeout_ns.
    task wait_frames;
        input integer n;
        input integer timeout_ns;
        integer t;
        begin
            t = 0;
            while (rx_frame_cnt < n && t < timeout_ns) begin
                #1000;
                t = t + 1000;
            end
            #(40 * BYTE_NS);   // let any spurious extra frame surface
        end
    endtask

    initial begin
        pass_cnt = 0; fail_cnt = 0; tx_frames = 0;
        rst_n = 0;
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arvalid = 0; rready = 0;
        tx_tdata = 0; tx_tvalid = 0; tx_tlast = 0;
        #100;
        rst_n = 1;
        #500;

`ifdef RGMII_10M
        $display("RGMII 10/100 loopback at 10M");
`else
        $display("RGMII 10/100 loopback at 100M");
`endif

        // tx_en | rx_en | promisc | speed | jumbo_en; accept broadcast.
        axi_write(8'h04, 32'h0000_0047 | (SPEED << 3));
        axi_write(8'h0C, 32'hFF_FF_FF_FF);
        axi_write(8'h10, 32'h0000_FF_FF);
        #(20 * BYTE_NS);   // cfg_speed crosses into the media domain
        mon_on = 1'b1;

        // T1: one minimum-size frame
        send_frame(46, 8'h10);
        wait_frames(1, 200 * BYTE_NS);
        check_int("min frame: frames received", rx_frame_cnt, 1);

        // T2: one standard-MTU frame
        send_frame(1500, 8'h20);
        wait_frames(2, 1700 * BYTE_NS);
        check_int("MTU frame: frames received", rx_frame_cnt, 2);

        // T3: three frames queued back to back; the TX FIFO holds them all, so
        // only gmii_cdc's inter-frame gap keeps them apart on the wire.
        send_frame(60, 8'h30);
        send_frame(100, 8'h40);
        send_frame(46, 8'h50);
        wait_frames(5, 600 * BYTE_NS);
        check_int("back-to-back: frames received", rx_frame_cnt, 5);

`ifndef RGMII_10M
        // T4: jumbo frame at 100M (MAX_FRAME on the wire)
        send_frame(9000, 8'h60);
        wait_frames(6, 9300 * BYTE_NS);
        check_int("jumbo frame: frames received", rx_frame_cnt, 6);
`endif

        // Content, errors and wire timing across all frames
        check_int("bad length or content", rx_bad_frames, 0);
        check_int("rx error beats", rx_err_cnt, 0);
        check_int("frames seen on the TX pins", tx_bursts, tx_frames);
        check_int("TXC periods not 2*HALF_PER", bad_period, 0);
        check_int("TXC high times not HALF_PER", bad_high, 0);
        $display("INFO: %0d TXC rises, min TXC-to-data distance %0.1f ns",
                 txc_rises, min_margin);
        if (min_margin > 7.999) begin
            $display("PASS: TXC edges >= 8 ns from TXD/TX_CTL changes");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: a TXC edge is %0.1f ns from a TXD/TX_CTL change", min_margin);
            fail_cnt = fail_cnt + 1;
        end

        // IFG: at least 12 byte times = 24 TXC cycles of TX_CTL low
        if (min_gap >= 24 && min_gap < 1000000) begin
            $display("PASS: shortest inter-frame gap %0d TXC cycles (>= 24)", min_gap);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: shortest inter-frame gap %0d TXC cycles, expected >= 24", min_gap);
            fail_cnt = fail_cnt + 1;
        end

        axi_read(8'h28, rd_result);
        check_int("TX_FRAME_CNT", rd_result, tx_frames);
        axi_read(8'h30, rd_result);
        check_int("RX_FRAME_CNT", rd_result, tx_frames);
        axi_read(8'h38, rd_result);
        check_int("RX_ERR", rd_result, 0);

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
`ifdef RGMII_10M
        #20000000;
`else
        #5000000;
`endif
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
