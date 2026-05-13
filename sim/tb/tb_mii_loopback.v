// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio � bard0 design
// tb_mii_loopback.v — Full MAC TX → MII → MAC RX loopback simulation
// Tests CRC through the complete nibble path
`timescale 1ns / 1ps

module tb_mii_loopback;

    reg clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    reg mii_tx_clk = 0;
    always #20 mii_tx_clk = ~mii_tx_clk;  // 25 MHz (MII 100Mbps)

    reg mii_rx_clk = 0;
    initial begin
        #10;
        forever #20 mii_rx_clk = ~mii_rx_clk;
    end

    reg rst_n = 0;
    initial begin
        #100 rst_n = 1;
    end

    // MII loopback wires: direct PHY-style connection with RX sampling on a
    // phase-shifted MII clock.
    wire [3:0] mii_txd, mii_rxd;
    wire       mii_tx_en, mii_rx_dv;
    assign mii_rxd   = mii_txd;
    assign mii_rx_dv = mii_tx_en;
    // GMII signals
    wire [7:0] gmii_txd, gmii_rxd;
    wire       gmii_tx_en, gmii_tx_er, gmii_rx_dv, gmii_rx_er;

    // MII interface
    wire tx_fifo_busy;

    mii_if u_mii (
        .clk(clk), .rst_n(rst_n),
        .mii_rxd(mii_rxd), .mii_rx_dv(mii_rx_dv), .mii_rx_er(1'b0),
        .mii_rx_clk(mii_rx_clk), .mii_col(1'b0), .mii_crs(1'b0),
        .mii_txd(mii_txd), .mii_tx_en(mii_tx_en), .mii_tx_clk(mii_tx_clk),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er),
        .mii_tx_clk_out(),
        .tx_busy(tx_fifo_busy),
        .dbg_tx_fifo_empty(), .dbg_rx_prog_empty(),
        .dbg_rx_rd_empty(), .dbg_rx_reading(), .dbg_rx_frames_pending()
    );

    // MAC TX
    reg  [7:0] tx_data;
    reg        tx_valid = 0, tx_last = 0;
    wire       tx_ready;

    eth_mac_tx u_mac_tx (
        .clk(clk), .rst_n(rst_n),
        .tx_start_ok(1'b1),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .s_axis_tdata(tx_data), .s_axis_tvalid(tx_valid),
        .s_axis_tready(tx_ready), .s_axis_tkeep(1'b1), .s_axis_tlast(tx_last),
        .tx_active()
    );

    // MAC RX
    wire [7:0] mac_rx_data;
    wire       mac_rx_valid, mac_rx_last;
    wire [1:0] mac_rx_tuser;
    wire mac_rx_error = mac_rx_tuser[0];
    wire mac_rx_sof = mac_rx_tuser[1];

    eth_mac_rx u_mac_rx (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er),
        .our_mac(48'hFF_FF_FF_FF_FF_FF),  // accept broadcast
        .promisc(1'b0),
        .passthrough(1'b0),
        .jumbo_en(1'b1),
        .mcast_hash_table(64'd0),
        .m_axis_tdata(mac_rx_data), .m_axis_tvalid(mac_rx_valid),
        .m_axis_tready(1'b1),
        .m_axis_tlast(mac_rx_last), .m_axis_terror(mac_rx_error), .m_axis_tsof(mac_rx_sof),
        .stat_done(), .stat_len(), .stat_err_fcs(), .stat_err_align(),
        .stat_err_overflow(), .stat_err_oversize(),
        .stat_is_bcast(), .stat_is_mcast()
    );

    // Frame to send: ICMP-length (74 bytes, like a real ping)
    localparam FRAME_LEN = 74;
    reg [7:0] frame [0:FRAME_LEN-1];
    integer i;
    initial begin
        // Dst MAC: ff:ff:ff:ff:ff:ff
        frame[0] = 8'hFF; frame[1] = 8'hFF; frame[2] = 8'hFF;
        frame[3] = 8'hFF; frame[4] = 8'hFF; frame[5] = 8'hFF;
        // Src MAC: 02:00:00:00:00:01
        frame[6] = 8'h02; frame[7] = 8'h00; frame[8] = 8'h00;
        frame[9] = 8'h00; frame[10] = 8'h00; frame[11] = 8'h01;
        // EtherType: 0x0800 (IPv4)
        frame[12] = 8'h08; frame[13] = 8'h00;
        // IP + ICMP payload (60 bytes)
        for (i = 14; i < FRAME_LEN; i = i + 1)
            frame[i] = i[7:0];
    end

    // TX: send frame using initial block (same approach as tb_gvcp_full)
    integer tx_idx;
    initial begin
        tx_valid = 0; tx_last = 0;
        @(posedge rst_n);
        #500;
        @(posedge clk);
        tx_valid <= 1;
        tx_data  <= frame[0];
        for (tx_idx = 1; tx_idx < FRAME_LEN; tx_idx = tx_idx + 1) begin
            @(posedge clk);
            while (!tx_ready) @(posedge clk);
            tx_data <= frame[tx_idx];
            tx_last <= (tx_idx == FRAME_LEN - 1);
        end
        @(posedge clk);
        while (!tx_ready) @(posedge clk);
        tx_valid <= 0;
        tx_last  <= 0;
    end

    // RX checker
    integer rx_cnt = 0;
    integer gmii_tx_byte_cnt = 0;
    integer gmii_rx_byte_cnt = 0;
    reg rx_frame_done = 0;
    reg rx_had_error = 0;
    reg rx_mac_ok = 0;
    reg [31:0] rx_crc_raw_at_last = 32'd0;
    integer rx_mismatch = 0;
    reg [7:0] gmii_tx_buf [0:127];
    reg [7:0] gmii_rx_buf [0:127];
    integer raw_idx;
    always @(posedge clk) begin
        if (gmii_tx_en) begin
            if (gmii_tx_byte_cnt < 128)
                gmii_tx_buf[gmii_tx_byte_cnt] <= gmii_txd;
            gmii_tx_byte_cnt <= gmii_tx_byte_cnt + 1;
        end
        if (gmii_rx_dv) begin
            if (gmii_rx_byte_cnt < 128)
                gmii_rx_buf[gmii_rx_byte_cnt] <= gmii_rxd;
            gmii_rx_byte_cnt <= gmii_rx_byte_cnt + 1;
        end
        if (mac_rx_valid) begin
            if (rx_cnt < FRAME_LEN && mac_rx_data !== frame[rx_cnt]) begin
                $display("RX mismatch at byte %0d: got %02x expected %02x",
                         rx_cnt, mac_rx_data, frame[rx_cnt]);
                rx_mismatch <= rx_mismatch + 1;
            end
            rx_cnt <= rx_cnt + 1;
        end
        if (mac_rx_last) begin
            rx_frame_done <= 1;
            rx_had_error  <= mac_rx_error;
            rx_mac_ok <= u_mac_rx.mac_ok;
            rx_crc_raw_at_last <= u_mac_rx.crc_out;
        end
    end

    // Test control
    initial begin
        $dumpfile("tb_mii_loopback.vcd");
        $dumpvars(0, tb_mii_loopback);

        #200;  // wait for reset

        // Wait for frame to be sent and received
        #200000;

        if (rx_frame_done) begin
            $display("RX CRC raw register = 0x%08X", rx_crc_raw_at_last);
            $display("rx_er_seen=%0d mac_ok=%0d", u_mac_rx.rx_er_seen, rx_mac_ok);
            $display("rx_mismatch=%0d", rx_mismatch);
            $display("gmii_tx_byte_cnt=%0d", gmii_tx_byte_cnt);
            $display("gmii_rx_byte_cnt=%0d", gmii_rx_byte_cnt);
            for (raw_idx = 0; raw_idx < gmii_tx_byte_cnt && raw_idx < 96; raw_idx = raw_idx + 1)
                if (raw_idx >= gmii_rx_byte_cnt || gmii_tx_buf[raw_idx] !== gmii_rx_buf[raw_idx])
                    $display("RAW mismatch at byte %0d: tx=%02x rx=%02x",
                             raw_idx, gmii_tx_buf[raw_idx],
                             (raw_idx < gmii_rx_byte_cnt) ? gmii_rx_buf[raw_idx] : 8'hxx);
            $display("Expected 0x2144DF1C or 0xDEBB20E3");
            if (rx_had_error) begin
                $display("FAIL: CRC ERROR on MII loopback! rx_bytes=%0d", rx_cnt);
            end else begin
                $display("PASS: MII loopback CRC OK, rx_bytes=%0d", rx_cnt);
            end
        end else begin
            $display("FAIL: No frame received after 200us");
        end

        $display("");
        if (!rx_had_error && rx_frame_done)
            $display("ALL TESTS PASSED");
        else
            $display("TESTS FAILED");

        $finish;
    end

endmodule


