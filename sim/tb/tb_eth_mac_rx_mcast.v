// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_eth_mac_rx_mcast.v - Testbench for MCAST_HASH_FILTER in eth_mac_rx
//
// Tests:
//   T1: Unicast to our_mac                    → accepted
//   T2: Broadcast (FF:FF:FF:FF:FF:FF)         → accepted
//   T3: Multicast 01:00:5E:00:00:01, hash=14, bit set in table → accepted
//   T4: Multicast 01:00:5E:00:00:02, hash=13, bit NOT set      → dropped
//   T5: 01:00:5E:00:00:01 after hash table cleared             → dropped
//
// Hash function (XOR-fold 48-bit MAC into 6 bits):
//   hash = mac[5:0] ^ mac[11:6] ^ mac[17:12] ^ mac[23:18] ^
//          mac[29:24] ^ mac[35:30] ^ mac[41:36] ^ mac[47:42]
//   01:00:5E:00:00:01 -> 0x0E (14), 01:00:5E:00:00:02 -> 0x0D (13)
//
// Uses eth_mac_tx to generate preamble/SFD/CRC; GMII loopback to eth_mac_rx.
// =============================================================================
`timescale 1ns / 1ps

module tb_eth_mac_rx_mcast;

    // ---- Clock / reset ----
    reg clk, rst_n;
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // ---- TX path ----
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

    // ---- GMII loopback: sample TX outputs on negedge to avoid NBA race ----
    // Both TX and RX are posedge-clocked. A direct combinational connection causes
    // eth_mac_rx to see one extra valid cycle (the pre-NBA value of gmii_tx_en).
    // Sampling on negedge ensures RX sees fully settled post-NBA values.
    reg [7:0] lb_rxd;
    reg       lb_rx_dv;
    reg       lb_rx_er;
    always @(negedge clk) begin
        lb_rxd   <= gmii_txd;
        lb_rx_dv <= gmii_tx_en;
        lb_rx_er <= gmii_tx_er;
    end

    // ---- RX path (MCAST_HASH_FILTER enabled) ----
    reg  [63:0] mcast_hash_table;

    wire [7:0]  rx_tdata;
    wire        rx_tvalid;
    wire        rx_tlast;
    wire        rx_terror;
    wire        rx_tsof;

    localparam [47:0] OUR_MAC = 48'h02_00_00_00_00_01;
    localparam [47:0] SRC_MAC = 48'h02_00_00_00_00_02;

    // MCAST_TABLE_01: bit 14 set (1<<14 = 0x4000)
    // Accepts 01:00:5E:00:00:01 (hash=14), rejects 01:00:5E:00:00:02 (hash=13).
    localparam [63:0] MCAST_TABLE_01 = 64'h0000_0000_0000_4000;

    eth_mac_rx #(.MCAST_HASH_FILTER(1)) u_rx (
        .clk              (clk),
        .rst_n            (rst_n),
        .gmii_rxd         (lb_rxd),
        .gmii_rx_dv       (lb_rx_dv),
        .gmii_rx_er       (lb_rx_er),
        .our_mac          (OUR_MAC),
        .promisc          (1'b0),
        .passthrough      (1'b0),
        .jumbo_en         (1'b1),
        .mcast_hash_table (mcast_hash_table),
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

    // ---- Good-frame counter (no CRC error) ----
    integer rx_good_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_good_cnt <= 0;
        else if (rx_tvalid && rx_tlast && !rx_terror)
            rx_good_cnt <= rx_good_cnt + 1;
    end

    integer pass_cnt, fail_cnt;

    task check_bool;
        input [255:0] name;
        input         actual;
        input         expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s", name);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s (got %0b, exp %0b)", name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ---- Frame buffer ----
    reg [7:0] fbuf [0:63];
    integer   flen;

    // Load a minimal 15-byte Ethernet header into fbuf; eth_mac_tx pads.
    task load_frame;
        input [47:0] dst;
        input [47:0] src;
        begin
            fbuf[0] = dst[47:40]; fbuf[1] = dst[39:32];
            fbuf[2] = dst[31:24]; fbuf[3] = dst[23:16];
            fbuf[4] = dst[15:8];  fbuf[5] = dst[7:0];
            fbuf[6] = src[47:40]; fbuf[7] = src[39:32];
            fbuf[8] = src[31:24]; fbuf[9] = src[23:16];
            fbuf[10] = src[15:8]; fbuf[11] = src[7:0];
            fbuf[12] = 8'h08; fbuf[13] = 8'h00;  // IPv4 ethertype
            fbuf[14] = 8'hAA;                     // 1-byte payload
            flen = 15;
        end
    endtask

    // Send fbuf[0..flen-1] over AXI4-Stream to eth_mac_tx.
    task send_frame;
        integer k;
        begin
            for (k = 0; k < flen; k = k + 1) begin
                @(negedge clk);
                tx_tdata  = fbuf[k];
                tx_tvalid = 1'b1;
                tx_tlast  = (k == flen - 1) ? 1'b1 : 1'b0;
                @(posedge clk);
                while (!tx_tready) @(posedge clk);
            end
            @(negedge clk);
            tx_tvalid = 1'b0;
            tx_tlast  = 1'b0;
        end
    endtask

    // Wait up to 300 cycles for a new good frame; sets wait_result.
    reg  wait_result;
    task wait_for_rx_frame;
        integer prev_cnt, i;
        begin
            prev_cnt    = rx_good_cnt;
            wait_result = 1'b0;
            for (i = 0; i < 300; i = i + 1) begin
                @(posedge clk);
                if (rx_good_cnt > prev_cnt) begin
                    wait_result = 1'b1;
                    i = 300;  // exit loop
                end
            end
        end
    endtask

    initial begin
        $dumpfile("tb_eth_mac_rx_mcast.vcd");
        $dumpvars(0, tb_eth_mac_rx_mcast);

        pass_cnt         = 0;
        fail_cnt         = 0;
        tx_tvalid        = 1'b0;
        tx_tlast         = 1'b0;
        tx_tdata         = 8'd0;
        mcast_hash_table = MCAST_TABLE_01;
        rst_n = 0;
        #100;
        rst_n = 1;
        #50;

        // =================================================================
        // T1: Unicast to our MAC — must be accepted
        // =================================================================
        load_frame(OUR_MAC, SRC_MAC);
        send_frame;
        wait_for_rx_frame;
        check_bool("T1: unicast accept", wait_result, 1'b1);
        #20;

        // =================================================================
        // T2: Broadcast — must be accepted regardless of hash table
        // =================================================================
        load_frame(48'hFF_FF_FF_FF_FF_FF, SRC_MAC);
        send_frame;
        wait_for_rx_frame;
        check_bool("T2: broadcast accept", wait_result, 1'b1);
        #20;

        // =================================================================
        // T3: Multicast 01:00:5E:00:00:01, hash=14, bit 14 SET → accept
        // =================================================================
        mcast_hash_table = MCAST_TABLE_01;   // bit 14 set
        load_frame(48'h01_00_5E_00_00_01, SRC_MAC);
        send_frame;
        wait_for_rx_frame;
        check_bool("T3: mcast hash hit accept", wait_result, 1'b1);
        #20;

        // =================================================================
        // T4: Multicast 01:00:5E:00:00:02, hash=13, bit 13 NOT set → drop
        // =================================================================
        load_frame(48'h01_00_5E_00_00_02, SRC_MAC);
        send_frame;
        wait_for_rx_frame;
        check_bool("T4: mcast hash miss drop", wait_result, 1'b0);
        #20;

        // =================================================================
        // T5: Clear hash table — 01:00:5E:00:00:01 must now be dropped
        // =================================================================
        mcast_hash_table = 64'h0;
        load_frame(48'h01_00_5E_00_00_01, SRC_MAC);
        send_frame;
        wait_for_rx_frame;
        check_bool("T5: mcast table clear drop", wait_result, 1'b0);
        #20;

        // =================================================================
        // Summary
        // =================================================================
        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

endmodule
