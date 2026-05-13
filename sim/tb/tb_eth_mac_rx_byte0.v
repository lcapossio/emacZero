// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_eth_mac_rx_byte0.v - Verify the first data byte after SFD is delivered
// Drives a single frame through eth_mac_rx (direct GMII loopback) and checks
// that the FIRST AXIS byte equals frame[0]. This regresses a real bug where
// the 6-stage delay pipe was tapped at pipe1 starting at byte_cnt=6, which
// missed the very first byte.
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_eth_mac_rx_byte0;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg  [7:0] tx_tdata;
    reg        tx_tvalid;
    wire       tx_tready;
    reg        tx_tlast;
    wire [7:0] gmii_txd;
    wire       gmii_tx_en;
    wire       gmii_tx_er;

    eth_mac_tx u_tx (
        .clk(clk), .rst_n(rst_n), .tx_start_ok(1'b1),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .s_axis_tdata(tx_tdata), .s_axis_tvalid(tx_tvalid),
        .s_axis_tready(tx_tready), .s_axis_tkeep(1'b1), .s_axis_tlast(tx_tlast),
        .tx_active(), .dbg_state(), .dbg_stall_cnt()
    );

    reg [7:0] lb_rxd;
    reg       lb_rx_dv;
    reg       lb_rx_er;
    always @(negedge clk) begin
        lb_rxd   <= gmii_txd;
        lb_rx_dv <= gmii_tx_en;
        lb_rx_er <= gmii_tx_er;
    end

    wire [7:0] rx_tdata;
    wire       rx_tvalid;
    wire       rx_tlast;
    wire       rx_terror;
    wire       rx_tsof;

    eth_mac_rx u_rx (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(lb_rxd), .gmii_rx_dv(lb_rx_dv), .gmii_rx_er(lb_rx_er),
        .our_mac(48'hFE_FF_FF_FF_FF_FF), .promisc(1'b0), .passthrough(1'b0), .jumbo_en(1'b1),
        .mcast_hash_table(64'd0),
        .m_axis_tdata(rx_tdata), .m_axis_tvalid(rx_tvalid), .m_axis_tready(1'b1),
        .m_axis_tlast(rx_tlast), .m_axis_terror(rx_terror), .m_axis_tsof(rx_tsof),
        .stat_done(), .stat_len(), .stat_err_fcs(), .stat_err_align(),
        .stat_err_overflow(), .stat_err_oversize(),
        .stat_is_bcast(), .stat_is_mcast()
    );

    localparam FRAME_LEN = 70;
    reg [7:0] frame [0:FRAME_LEN-1];
    integer i;
    initial begin
        // Use unique first byte 0xFE so we can detect drops vs duplicates
        frame[0]=8'hFE;
        for (i = 1; i < 6; i = i + 1) frame[i] = 8'hFF;
        frame[6]=8'h02; frame[7]=8'h00; frame[8]=8'h00;
        frame[9]=8'h00; frame[10]=8'h00; frame[11]=8'h01;
        frame[12]=8'h08; frame[13]=8'h00;
        for (i = 14; i < FRAME_LEN; i = i + 1) frame[i] = i[7:0];
    end

    reg [7:0] rx_buf [0:FRAME_LEN-1];
    integer   rx_cnt;
    reg       rx_done;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_cnt  <= 0;
            rx_done <= 0;
        end else if (rx_tvalid && !rx_done) begin
            if (rx_cnt < FRAME_LEN)
                rx_buf[rx_cnt] <= rx_tdata;
            rx_cnt <= rx_cnt + 1;
            if (rx_tlast)
                rx_done <= 1;
        end
    end

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    initial begin
        $dumpfile("tb_eth_mac_rx_byte0.vcd");
        $dumpvars(0, tb_eth_mac_rx_byte0);

        tx_tdata=0; tx_tvalid=0; tx_tlast=0;
        #100; rst_n=1; #100;

        @(negedge clk);
        for (i = 0; i < FRAME_LEN; i = i + 1) begin
            tx_tdata = frame[i]; tx_tvalid=1; tx_tlast=(i==FRAME_LEN-1);
            @(negedge clk);
            while (!tx_tready) @(negedge clk);
        end
        tx_tvalid=0; tx_tlast=0;

        // Wait for RX to complete
        repeat (200) @(posedge clk);

        // ---- Verify first byte ----
        if (rx_buf[0] === 8'hFE) begin
            $display("PASS: rx_buf[0] = 0xFE (first byte preserved)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: rx_buf[0] = 0x%02x, expected 0xFE", rx_buf[0]);
            fail_cnt = fail_cnt + 1;
        end

        // ---- Verify byte count ----
        if (rx_cnt === FRAME_LEN) begin
            $display("PASS: rx_cnt = %0d", rx_cnt);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: rx_cnt = %0d, expected %0d", rx_cnt, FRAME_LEN);
            fail_cnt = fail_cnt + 1;
        end

        // ---- Verify all bytes match ----
        begin : verify_all
            integer mismatch;
            mismatch = 0;
            for (i = 0; i < FRAME_LEN && i < rx_cnt; i = i + 1)
                if (rx_buf[i] !== frame[i])
                    mismatch = mismatch + 1;
            if (mismatch == 0) begin
                $display("PASS: all %0d bytes match", FRAME_LEN);
                pass_cnt = pass_cnt + 1;
            end else begin
                $write("FAIL: %0d byte mismatches. RX: ", mismatch);
                for (i = 0; i < FRAME_LEN && i < 20; i = i + 1)
                    $write("%02x ", rx_buf[i]);
                $display("");
                $write("EXPECTED: ");
                for (i = 0; i < FRAME_LEN && i < 20; i = i + 1)
                    $write("%02x ", frame[i]);
                $display("");
                fail_cnt = fail_cnt + 1;
            end
        end

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #200_000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
