// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_eth_mac_jumbo.v - Jumbo frame test for eth_mac
// Sends a single 5000-byte frame through eth_mac TX (MII path) and verifies
// the GMII TX-side byte stream has the right preamble/SFD, frame length,
// and CRC tail.
// Verilog 2001
// =============================================================================

`timescale 1ns/1ps

module tb_eth_mac_jumbo;

    reg clk = 0;
    always #5 clk = ~clk;     // 100 MHz

    reg mii_clk = 0;
    always #20 mii_clk = ~mii_clk;  // 25 MHz (MII)

    reg rst_n = 0;
    initial begin
        #100 rst_n = 1;
    end

    wire [3:0] mii_txd;
    wire       mii_tx_en;
    wire [7:0] dbg_gmii_txd;
    wire       dbg_gmii_tx_en;
    wire       tx_ready;

    reg  [7:0] tx_data  = 8'd0;
    reg        tx_valid = 1'b0;
    reg        tx_last  = 1'b0;

    // MAX_FRAME=9018 so 5000 bytes fits.
    eth_mac #(.MAX_FRAME(9018), .MII_DEBUG(1)) u_mac (
        .clk              (clk),
        .rst_n            (rst_n),
        .mii_txd          (mii_txd),
        .mii_tx_en        (mii_tx_en),
        .mii_tx_clk       (mii_clk),
        .mii_rxd          (4'd0),
        .mii_rx_dv        (1'b0),
        .mii_rx_er        (1'b0),
        .mii_rx_clk       (mii_clk),
        .mii_col          (1'b0),
        .mii_crs          (1'b0),
        .our_mac          (48'h02_00_00_00_00_01),
        .promisc          (1'b0),
        .s_axis_tdata     (tx_data),
        .s_axis_tvalid    (tx_valid),
        .s_axis_tready    (tx_ready),
        .s_axis_tlast     (tx_last),
        .s_axis_tkeep     (1'b1),
        .m_axis_tdata     (),
        .m_axis_tvalid    (),
        .m_axis_tready    (1'b1),
        .m_axis_tlast     (),
        .m_axis_terror    (),
        .m_axis_tsof      (),
        .tx_active        (),
        .tx_fifo_busy_out (),
        .tx_fifo_level_out(),
        .dbg_tx_fifo_empty(),
        .dbg_rx_prog_empty(),
        .dbg_rx_rd_empty  (),
        .dbg_rx_reading   (),
        .dbg_rx_frames_pending(),
        .dbg_gmii_txd     (dbg_gmii_txd),
        .dbg_gmii_tx_en   (dbg_gmii_tx_en),
        .dbg_gmii_rxd     (),
        .dbg_gmii_rx_dv   ()
    );

    integer pass_cnt = 0, fail_cnt = 0;

    localparam integer JUMBO_LEN = 5000;

    // Capture the GMII TX byte stream so we can decode preamble/SFD/data
    reg [7:0] gmii_capture [0:8191];
    integer cap_idx;
    reg     capturing;

    always @(posedge clk) begin
        if (!rst_n) begin
            cap_idx   <= 0;
            capturing <= 1'b0;
        end else if (dbg_gmii_tx_en) begin
            if (cap_idx < 8192) gmii_capture[cap_idx] <= dbg_gmii_txd;
            cap_idx   <= cap_idx + 1;
            capturing <= 1'b1;
        end
    end

    // ---- Send the jumbo frame ----
    integer i;

    initial begin
        $dumpfile("tb_eth_mac_jumbo.vcd");
        $dumpvars(0, tb_eth_mac_jumbo);

        @(posedge rst_n);
        @(posedge clk);

        // Drive frame body
        @(negedge clk);
        for (i = 0; i < JUMBO_LEN; i = i + 1) begin
            tx_data  = i[7:0];
            tx_valid = 1'b1;
            tx_last  = (i == JUMBO_LEN - 1);
            @(negedge clk);
            // Wait for tx_ready if asserted low (FIFO full)
            if (i != JUMBO_LEN - 1) begin
                while (!tx_ready) @(negedge clk);
            end
        end
        tx_valid = 1'b0;
        tx_last  = 1'b0;

        // Wait for MAC to drain. JUMBO_LEN bytes + preamble(7)+SFD(1)+CRC(4) = 5012.
        // At 100 MHz GMII byte rate, that's 50 us. Plus padding/IFG. Wait 1 ms safe.
        #1_000_000;

        // ---- Verify ----
        // 1. Preamble: 7 bytes of 0x55
        // 2. SFD: 1 byte of 0xD5
        // 3. Frame body: JUMBO_LEN bytes matching i[7:0]
        // 4. CRC tail: 4 bytes (we don't verify the CRC value, just that the
        //    captured length is preamble+sfd+jumbo+crc)
        if (cap_idx >= 7+1+JUMBO_LEN+4) begin
            $display("PASS: GMII TX captured %0d bytes (>= %0d expected)",
                     cap_idx, 7+1+JUMBO_LEN+4);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: GMII TX captured %0d bytes (expected >= %0d)",
                     cap_idx, 7+1+JUMBO_LEN+4);
            fail_cnt = fail_cnt + 1;
        end

        // Check preamble bytes 0..6 = 0x55
        begin : pre_check
            integer j; reg bad;
            bad = 0;
            for (j = 0; j < 7; j = j + 1) begin
                if (gmii_capture[j] !== 8'h55) bad = 1;
            end
            if (!bad) begin
                $display("PASS: preamble (7x 0x55)");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: preamble corrupted");
                fail_cnt = fail_cnt + 1;
            end
        end

        // Check SFD byte 7 = 0xD5
        if (gmii_capture[7] === 8'hD5) begin
            $display("PASS: SFD = 0xD5");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: SFD = 0x%02x (expected 0xD5)", gmii_capture[7]);
            fail_cnt = fail_cnt + 1;
        end

        // Check first 16 frame bytes match input pattern
        begin : data_check
            integer j; reg bad;
            bad = 0;
            for (j = 0; j < 16; j = j + 1) begin
                if (gmii_capture[8 + j] !== j[7:0]) begin
                    $display("  byte[%0d] got 0x%02x, expected 0x%02x",
                             j, gmii_capture[8 + j], j[7:0]);
                    bad = 1;
                end
            end
            if (!bad) begin
                $display("PASS: first 16 frame bytes match input");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: frame body corrupted at start");
                fail_cnt = fail_cnt + 1;
            end
        end

        // Check last 16 frame bytes (just before CRC)
        begin : data_check_end
            integer j; reg bad;
            integer frame_start;
            frame_start = 8;  // after preamble+SFD
            bad = 0;
            for (j = JUMBO_LEN - 16; j < JUMBO_LEN; j = j + 1) begin
                if (gmii_capture[frame_start + j] !== j[7:0]) begin
                    $display("  byte[%0d] got 0x%02x, expected 0x%02x",
                             j, gmii_capture[frame_start + j], j[7:0]);
                    bad = 1;
                end
            end
            if (!bad) begin
                $display("PASS: last 16 frame bytes match input (jumbo end)");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: frame body corrupted at end of jumbo");
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
        #5_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
