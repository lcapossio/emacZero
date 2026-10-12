// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_eth_mac_sys_pause.v - 802.3x PAUSE through eth_mac_sys (GMII, 125 MHz)
//   - A PAUSE frame sent with PAUSE_CTRL[0] goes out as one 64-byte frame and,
//     with the GMII pins looped back, is received and counted.
//   - With PAUSE_CTRL[1] (rx_en), the received quanta holds off the next TX
//     frame for quanta x 512 bit-times; without it the frame is only counted.
//   - A user frame queued behind a PAUSE frame goes out as a separate frame:
//     the PAUSE frame's last byte carries tlast.
//   - Frames injected on the RX pins: a valid PAUSE frame counts; one with a
//     bad FCS, with rx_er, or shorter than 64 bytes does not.
//   - Writing PAUSE_RX_CNT clears both PAUSE counters.
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_eth_mac_sys_pause;

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
        .MAX_FRAME     (1518),
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
        .m_axis_tdata   (),
        .m_axis_tvalid  (),
        .m_axis_tready  (1'b1),
        .m_axis_tlast   (),
        .m_axis_terror  (),
        .m_axis_tsof    (),
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

    // ---- Stand-in PHY: TX pins loop back to RX unless the bench injects ----
    reg       inject;
    reg [7:0] inj_d;
    reg       inj_dv, inj_er;

    always @(posedge gmii_txc or negedge rst_n) begin
        if (!rst_n) begin
            gmii_rxd   <= 8'd0;
            gmii_rx_dv <= 1'b0;
            gmii_rx_er <= 1'b0;
        end else if (inject) begin
            gmii_rxd   <= inj_d;
            gmii_rx_dv <= inj_dv;
            gmii_rx_er <= inj_er;
        end else begin
            gmii_rxd   <= gmii_txd;
            gmii_rx_dv <= gmii_tx_en;
            gmii_rx_er <= gmii_tx_er;
        end
    end

    // ---- TX wire monitor: bytes per tx_en burst, and when each burst starts ----
    integer wire_n, wire_cnt, cur_len;
    integer wire_len   [0:31];
    time    wire_start [0:31];
    always @(posedge gmii_txc or negedge rst_n) begin
        if (!rst_n) begin
            wire_n  <= 0;
            cur_len <= 0;
        end else if (gmii_tx_en) begin
            if (cur_len == 0 && wire_n < 32)
                wire_start[wire_n] <= $time;
            cur_len <= cur_len + 1;
        end else if (cur_len != 0) begin
            if (wire_n < 32)
                wire_len[wire_n] <= cur_len;
            wire_n  <= wire_n + 1;
            cur_len <= 0;
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

    // ---- AXIS TX: a broadcast frame of `len` bytes before the FCS. Returns
    // once the last byte is accepted. tready is sampled mid-cycle, after the
    // byte is presented: it holds that value to the next rising edge, where
    // the transfer happens. ----
    time    tx_start_t;
    task send_frame;
        input integer len;
        integer k;
        begin
            @(negedge sys_clk);
            tx_start_t = $time;
            for (k = 0; k < len; k = k + 1) begin
                tx_tdata  = (k < 6) ? 8'hFF : (k == 12) ? 8'h08 : k[7:0];
                tx_tvalid = 1;
                tx_tlast  = (k == len - 1);
                #1;
                while (!tx_tready) begin
                    @(negedge sys_clk);
                    #1;
                end
                @(negedge sys_clk);
            end
            tx_tvalid = 0; tx_tlast = 0;
        end
    endtask

    // ---- RX injection: preamble, SFD, `len` frame bytes, FCS ----
    reg [7:0] fr [0:127];

    function [31:0] crc_byte;
        input [31:0] c;
        input [7:0]  d;
        integer i;
        reg [31:0] x;
        begin
            x = c ^ {24'd0, d};
            for (i = 0; i < 8; i = i + 1)
                x = x[0] ? ({1'b0, x[31:1]} ^ 32'hEDB88320) : {1'b0, x[31:1]};
            crc_byte = x;
        end
    endfunction

    // A PAUSE frame of `len` bytes before the FCS (60 is the minimum frame).
    task build_pause;
        input integer len;
        input [15:0]  quanta;
        integer k;
        begin
            for (k = 0; k < 128; k = k + 1) fr[k] = 8'h00;
            fr[0] = 8'h01; fr[1] = 8'h80; fr[2] = 8'hC2;
            fr[3] = 8'h00; fr[4] = 8'h00; fr[5] = 8'h01;
            fr[6] = 8'h02; fr[7] = 8'h11; fr[8] = 8'h22;
            fr[9] = 8'h33; fr[10] = 8'h44; fr[11] = 8'h55;
            fr[12] = 8'h88; fr[13] = 8'h08; fr[14] = 8'h00; fr[15] = 8'h01;
            fr[16] = quanta[15:8]; fr[17] = quanta[7:0];
        end
    endtask

    // bad_fcs flips one FCS bit; er_at >= 0 raises rx_er on that frame byte.
    task inject_frame;
        input integer len;
        input         bad_fcs;
        input integer er_at;
        integer k;
        reg [31:0] c, fcs;
        begin
            c = 32'hFFFFFFFF;
            for (k = 0; k < len; k = k + 1) c = crc_byte(c, fr[k]);
            fcs = ~c;
            if (bad_fcs) fcs = fcs ^ 32'h0000_0100;
            inject = 1;
            @(negedge gmii_txc);
            for (k = 0; k < 7; k = k + 1) begin
                inj_d = 8'h55; inj_dv = 1; inj_er = 0;
                @(negedge gmii_txc);
            end
            inj_d = 8'hD5;
            @(negedge gmii_txc);
            for (k = 0; k < len + 4; k = k + 1) begin
                inj_d  = (k < len) ? fr[k] : fcs[8 * (k - len) +: 8];
                inj_er = (k == er_at);
                @(negedge gmii_txc);
            end
            inj_dv = 0; inj_er = 0; inj_d = 0;
            repeat (20) @(negedge gmii_txc);
            inject = 0;
            repeat (200) @(posedge sys_clk);   // through the RX CDC FIFO
        end
    endtask

    integer pass_cnt, fail_cnt, n0;
    time    delay_t;

    task check;
        input [511:0] name;
        input         cond;
        begin
            if (cond) begin
                $display("PASS: %0s", name);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s", name);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task wait_wire;
        input integer n;
        integer guard;
        begin
            guard = 0;
            while (wire_n < n && guard < 200000) begin
                @(posedge sys_clk);
                guard = guard + 1;
            end
        end
    endtask

    // 1G pause quantum = 512 ns. QUANTA quanta = 51.2 us.
    localparam [15:0] QUANTA = 16'd100;

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        rst_n = 0;
        inject = 0; inj_d = 0; inj_dv = 0; inj_er = 0;
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arvalid = 0; rready = 0;
        tx_tdata = 0; tx_tvalid = 0; tx_tlast = 0;
        #100;
        rst_n = 1;
        #200;

        axi_write(8'h04, 32'h0000_0007);       // TX + RX + promiscuous
        axi_write(8'h88, {16'd0, QUANTA});

        // ---- 1. PAUSE sent with rx_en: looped back, counted, holds off TX ----
        axi_write(8'h84, 32'h0000_0003);       // rx_en + tx_send
        wait_wire(1);
        check("PAUSE frame is 72 wire bytes (preamble, SFD, 60 + FCS)",
              wire_len[0] == 72);
        repeat (200) @(posedge sys_clk);
        axi_read(8'h90, rd_result);
        check("PAUSE_TX_CNT = 1", rd_result == 1);
        axi_read(8'h8C, rd_result);
        check("looped-back PAUSE frame counted in PAUSE_RX_CNT", rd_result == 1);
        n0 = wire_n;
        send_frame(60);
        wait_wire(n0 + 1);
        delay_t = wire_start[n0] - tx_start_t;
        $display("      next frame started %0d ns after it was offered", delay_t);
        check("rx_en: next frame held off by the received quanta (> 40 us)",
              delay_t > 40_000);

        // ---- 2. Same without rx_en: counted, no hold-off ----
        axi_write(8'h84, 32'h0000_0001);       // tx_send only
        wait_wire(n0 + 2);
        repeat (200) @(posedge sys_clk);
        axi_read(8'h8C, rd_result);
        check("rx_en off: PAUSE frame still counted", rd_result == 2);
        n0 = wire_n;
        send_frame(60);
        wait_wire(n0 + 1);
        delay_t = wire_start[n0] - tx_start_t;
        check("rx_en off: next frame not held off (< 5 us)", delay_t < 5_000);

        // ---- 3. User frame queued behind a PAUSE frame: two frames on the wire ----
        n0 = wire_n;
        fork
            axi_write(8'h84, 32'h0000_0001);
            begin
                repeat (3) @(posedge sys_clk);
                send_frame(100);
            end
        join
        wait_wire(n0 + 2);
        repeat (200) @(posedge sys_clk);
        check("PAUSE then queued frame: PAUSE frame ends at 72 bytes",
              wire_len[n0] == 72);
        check("PAUSE then queued frame: user frame is separate (112 bytes)",
              wire_len[n0 + 1] == 112);

        // ---- 4. Injected frames: only a valid PAUSE frame counts ----
        axi_write(8'h8C, 32'd0);               // clears both counters
        axi_read(8'h8C, rd_result);
        check("write to PAUSE_RX_CNT clears it", rd_result == 0);
        axi_read(8'h90, rd_result);
        check("write to PAUSE_RX_CNT clears PAUSE_TX_CNT too", rd_result == 0);

        build_pause(60, 16'd5);
        inject_frame(60, 1'b0, -1);
        axi_read(8'h8C, rd_result);
        check("injected valid PAUSE frame counted", rd_result == 1);
        inject_frame(60, 1'b1, -1);
        axi_read(8'h8C, rd_result);
        check("PAUSE frame with a bad FCS ignored", rd_result == 1);
        inject_frame(60, 1'b0, 30);
        axi_read(8'h8C, rd_result);
        check("PAUSE frame with rx_er ignored", rd_result == 1);
        build_pause(56, 16'd5);
        inject_frame(56, 1'b0, -1);
        axi_read(8'h8C, rd_result);
        check("PAUSE frame shorter than 64 bytes ignored", rd_result == 1);
        build_pause(100, 16'd5);
        inject_frame(100, 1'b0, -1);
        axi_read(8'h8C, rd_result);
        check("PAUSE frame longer than 64 bytes counted", rd_result == 2);
        build_pause(60, 16'd5);
        fr[13] = 8'h09;                        // EtherType 0x8809: not MAC Control
        inject_frame(60, 1'b0, -1);
        axi_read(8'h8C, rd_result);
        check("other EtherType ignored", rd_result == 2);

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
