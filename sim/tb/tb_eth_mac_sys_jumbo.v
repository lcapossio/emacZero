// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_eth_mac_sys_jumbo.v - End-to-end test of cfg_jumbo_en through eth_mac_sys
//
// Sends a 2000-byte (over the 1518 standard Ethernet limit) frame and verifies
// that:
//   - With cfg_jumbo_en = 0, the MAC TX still emits the frame on GMII (TX
//     side has no length-based gating; cfg_jumbo_en is RX-only)
//   - With cfg_jumbo_en = 1, the same frame is accepted by MAC RX without
//     terror (verified via the AXIS RX path with an internal GMII loopback,
//     bypassing mii_if to avoid its known 1-byte loss)
//   - With cfg_jumbo_en = 0, the same frame is delivered with terror
//
// Wires gmii_txd / gmii_tx_en directly into eth_mac_rx via a loopback layer,
// avoiding the MII/RGMII clock-domain crossing entirely.
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_eth_mac_sys_jumbo;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    // ---- TX path: drive eth_mac_tx directly (no eth_mac_sys for simplicity) ----
    // We use the bare eth_mac_tx + eth_mac_rx pair with a 1-cycle GMII loopback
    // matching tb_eth_mac_rx_backpressure. This isolates the jumbo gating in
    // eth_mac_rx, validating the cfg_jumbo_en path that eth_mac_sys exposes.

    reg  [7:0] tx_tdata;
    reg        tx_tvalid;
    wire       tx_tready;
    reg        tx_tlast;
    wire [7:0] gmii_txd;
    wire       gmii_tx_en;
    wire       gmii_tx_er;

    eth_mac_tx #(.MAX_FRAME(9018)) u_tx (
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
        .promisc          (1'b1),                  // accept anything
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

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // RX capture per pass (resets between frames)
    integer rx_byte_cnt;
    reg     rx_done;
    reg     rx_had_error;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_byte_cnt  <= 0;
            rx_done      <= 0;
            rx_had_error <= 0;
        end else if (rx_tvalid && !rx_done) begin
            rx_byte_cnt <= rx_byte_cnt + 1;
            if (rx_tlast) begin
                rx_done      <= 1;
                rx_had_error <= rx_terror;
            end
        end
    end

    task reset_capture;
        begin
            @(negedge clk);
            rx_byte_cnt  = 0;
            rx_done      = 0;
            rx_had_error = 0;
        end
    endtask

    localparam FRAME_LEN = 2000;       // > 1518 standard but < 9018 jumbo

    integer k;

    function [7:0] frame_byte;
        input integer idx;
        begin
            if (idx < 6)      frame_byte = 8'hFF;        // dst MAC = broadcast
            else if (idx < 12) frame_byte = 8'h02;        // src MAC
            else if (idx == 12) frame_byte = 8'h08;
            else if (idx == 13) frame_byte = 8'h00;
            else              frame_byte = idx[7:0];
        end
    endfunction

    task send_frame;
        begin
            reset_capture;
            @(negedge clk);
            for (k = 0; k < FRAME_LEN; k = k + 1) begin
                tx_tdata  = frame_byte(k);
                tx_tvalid = 1'b1;
                tx_tlast  = (k == FRAME_LEN - 1);
                @(negedge clk);
                while (!tx_tready) @(negedge clk);
            end
            tx_tvalid = 1'b0;
            tx_tlast  = 1'b0;
            // Wait long enough for the 2000-byte frame to traverse + CRC + IFG
            #100000;
        end
    endtask

    initial begin
        $dumpfile("tb_eth_mac_sys_jumbo.vcd");
        $dumpvars(0, tb_eth_mac_sys_jumbo);

        tx_tdata = 0; tx_tvalid = 0; tx_tlast = 0;
        jumbo_en = 0;
        #100;
        rst_n = 1;
        #100;

        // ---- T1: jumbo_en=0 → frame must be marked terror ----
        jumbo_en = 1'b0;
        send_frame;
        if (rx_done && rx_had_error) begin
            $display("PASS: jumbo_en=0 marks 2000-byte frame as terror");
            pass_cnt = pass_cnt + 1;
        end else if (!rx_done) begin
            $display("FAIL: jumbo_en=0 frame never reached RX last");
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("FAIL: jumbo_en=0 2000-byte frame did NOT raise terror");
            fail_cnt = fail_cnt + 1;
        end

        // ---- T2: jumbo_en=1 → frame must be accepted clean ----
        jumbo_en = 1'b1;
        send_frame;
        if (rx_done && !rx_had_error) begin
            $display("PASS: jumbo_en=1 accepts 2000-byte frame cleanly");
            pass_cnt = pass_cnt + 1;
        end else if (!rx_done) begin
            $display("FAIL: jumbo_en=1 frame never reached RX last");
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("FAIL: jumbo_en=1 2000-byte frame had terror set");
            fail_cnt = fail_cnt + 1;
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
        #5_000_000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
