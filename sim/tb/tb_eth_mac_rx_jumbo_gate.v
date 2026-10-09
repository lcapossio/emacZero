// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_eth_mac_rx_jumbo_gate.v - Verify the RX frame-size limits
// Sends a 1600-byte frame (over the 1518 standard limit) twice:
//   - jumbo_en=0 -> RX must mark it as terror (oversize error)
//   - jumbo_en=1 -> RX must accept it cleanly
// Then, with jumbo_en=0, frames at the standard limit with and without an
// 802.1Q / 802.1ad tag: a tagged frame may be 1522 wire bytes, an untagged one
// 1518. Lengths below are AXIS bytes; the wire adds the 4-byte FCS.
// Verilog 2001
// =============================================================================

`timescale 1ns/1ps

module tb_eth_mac_rx_jumbo_gate;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;  // 100 MHz

    reg  [7:0] tx_tdata;
    reg        tx_tvalid;
    wire       tx_tready;
    reg        tx_tlast;

    wire [7:0] gmii_txd;
    wire       gmii_tx_en;
    wire       gmii_tx_er;

    eth_mac_tx u_tx (
        .clk           (clk),
        .rst_n         (rst_n),
        .tx_start_ok   (1'b1),
        .gmii_txd      (gmii_txd),
        .gmii_tx_en    (gmii_tx_en),
        .gmii_tx_er    (gmii_tx_er),
        .s_axis_tdata  (tx_tdata),
        .s_axis_tvalid (tx_tvalid),
        .s_axis_tready (tx_tready),
        .s_axis_tkeep  (1'b1),
        .s_axis_tlast  (tx_tlast),
        .tx_active     (),
        .dbg_state     (),
        .dbg_stall_cnt ()
    );

    reg [7:0] lb_rxd;
    reg       lb_rx_dv;
    reg       lb_rx_er;
    always @(negedge clk) begin
        lb_rxd   <= gmii_txd;
        lb_rx_dv <= gmii_tx_en;
        lb_rx_er <= gmii_tx_er;
    end

    reg jumbo_en;

    wire [7:0] rx_tdata;
    wire       rx_tvalid;
    wire       rx_tlast;
    wire       rx_terror;
    wire       rx_tsof;

    eth_mac_rx u_rx (
        .clk              (clk),
        .rst_n            (rst_n),
        .gmii_rxd         (lb_rxd),
        .gmii_rx_dv       (lb_rx_dv),
        .gmii_rx_er       (lb_rx_er),
        .our_mac          (48'hFF_FF_FF_FF_FF_FF),
        .promisc          (1'b0),
        .passthrough      (1'b0),
        .jumbo_en         (jumbo_en),
        .mcast_hash_table (64'd0),
        .m_axis_tdata     (rx_tdata),
        .m_axis_tvalid    (rx_tvalid),
        .m_axis_tready    (1'b1),
        .m_axis_tlast     (rx_tlast),
        .m_axis_terror    (rx_terror),
        .m_axis_tsof      (rx_tsof),
        .stat_done(), .stat_len(), .stat_err_fcs(), .stat_err_align(),
        .stat_err_overflow(), .stat_err_oversize(),
        .stat_is_bcast(), .stat_is_mcast()
    );

    integer pass_cnt = 0, fail_cnt = 0;

    reg saw_last;
    reg saw_terror;
    integer rx_byte_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saw_last    <= 1'b0;
            saw_terror  <= 1'b0;
            rx_byte_cnt <= 0;
        end else begin
            if (rx_tvalid) rx_byte_cnt <= rx_byte_cnt + 1;
            if (rx_tvalid && rx_tlast) begin
                saw_last   <= 1'b1;
                saw_terror <= rx_terror;
            end
        end
    end

    integer i;
    integer frame_len;
    reg [15:0] frame_tpid;     // bytes 12-13; 0 = untagged sequential pattern

    function [7:0] frame_byte;
        input integer idx;
        begin
            // First 6 bytes = dst MAC = broadcast (FF) so RX accepts.
            // Bytes 12-13 = frame_tpid when set. Rest = sequential pattern.
            if (idx < 6)                        frame_byte = 8'hFF;
            else if (idx == 12 && frame_tpid != 0) frame_byte = frame_tpid[15:8];
            else if (idx == 13 && frame_tpid != 0) frame_byte = frame_tpid[7:0];
            else                                frame_byte = idx[7:0];
        end
    endfunction

    task send_frame;
        begin
            saw_last    = 1'b0;
            saw_terror  = 1'b0;
            rx_byte_cnt = 0;
            @(negedge clk);
            for (i = 0; i < frame_len; i = i + 1) begin
                tx_tdata  = frame_byte(i);
                tx_tvalid = 1'b1;
                tx_tlast  = (i == frame_len - 1);
                @(negedge clk);
                while (!tx_tready) @(negedge clk);
            end
            tx_tvalid = 1'b0;
            tx_tlast  = 1'b0;

            // Wait for the loopback frame to come back through RX
            #200000;
        end
    endtask

    // Send one frame and check whether it ends with terror.
    task check_frame;
        input integer   len;
        input [15:0]    tpid;
        input           want_terror;
        begin
            frame_len  = len;
            frame_tpid = tpid;
            send_frame();
            if (saw_last && saw_terror == want_terror) begin
                $display("PASS: %0d-byte frame, TPID %04h, jumbo_en=%0d: %0s",
                         len + 4, tpid, jumbo_en,
                         want_terror ? "oversize" : "accepted");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0d-byte frame, TPID %04h, jumbo_en=%0d: last=%0d terror=%0d",
                         len + 4, tpid, jumbo_en, saw_last, saw_terror);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_eth_mac_rx_jumbo_gate.vcd");
        $dumpvars(0, tb_eth_mac_rx_jumbo_gate);

        tx_tdata = 0; tx_tvalid = 0; tx_tlast = 0;
        jumbo_en = 0;
        rst_n = 0;
        #100;
        rst_n = 1;
        #50;

        // ---- Frame 1: jumbo_en = 0 ----
        jumbo_en   = 1'b0;
        frame_len  = 1600;     // > 1518 (oversize for standard)
        frame_tpid = 16'h0000;
        send_frame();
        if (saw_last && saw_terror) begin
            $display("PASS: 1600-byte frame rejected with terror at jumbo_en=0");
            pass_cnt = pass_cnt + 1;
        end else if (!saw_last) begin
            $display("FAIL: jumbo_en=0 frame never reached RX last");
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("FAIL: jumbo_en=0 1600-byte frame did NOT raise terror");
            fail_cnt = fail_cnt + 1;
        end

        // ---- Frame 2: jumbo_en = 1 ----
        jumbo_en = 1'b1;
        send_frame();
        if (saw_last && !saw_terror) begin
            $display("PASS: 1600-byte frame accepted cleanly at jumbo_en=1");
            pass_cnt = pass_cnt + 1;
        end else if (!saw_last) begin
            $display("FAIL: jumbo_en=1 frame never reached RX last");
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("FAIL: jumbo_en=1 1600-byte frame had terror set");
            fail_cnt = fail_cnt + 1;
        end

        // ---- VLAN allowance at the standard limit (jumbo_en = 0) ----
        jumbo_en = 1'b0;
        check_frame(1514, 16'h0000, 1'b0);   // 1518 untagged: at the limit
        check_frame(1518, 16'h0000, 1'b1);   // 1522 untagged: oversize
        check_frame(1518, 16'h8100, 1'b0);   // 1522 802.1Q: accepted
        check_frame(1518, 16'h88A8, 1'b0);   // 1522 802.1ad: accepted
        check_frame(1519, 16'h8100, 1'b1);   // 1523 802.1Q: oversize
        check_frame(1518, 16'h9100, 1'b1);   // 0x9100 is not a recognised TPID

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
