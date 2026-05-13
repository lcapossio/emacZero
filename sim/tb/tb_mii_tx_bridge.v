// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
`timescale 1ns / 1ps

module tb_mii_tx_bridge;

    reg clk = 0;
    always #5 clk = ~clk;

    reg mii_clk = 0;
    always #20 mii_clk = ~mii_clk;

    reg rst_n = 0;
    initial begin
        #100 rst_n = 1;
    end

    wire [3:0] mii_txd;
    wire       mii_tx_en;
    wire [7:0] gmii_txd;
    wire       gmii_tx_en;
    wire       gmii_tx_er;
    wire       tx_busy;

    mii_if u_mii (
        .clk(clk),
        .rst_n(rst_n),
        .mii_rxd(4'd0),
        .mii_rx_dv(1'b0),
        .mii_rx_er(1'b0),
        .mii_rx_clk(mii_clk),
        .mii_col(1'b0),
        .mii_crs(1'b0),
        .mii_txd(mii_txd),
        .mii_tx_en(mii_tx_en),
        .mii_tx_clk(mii_clk),
        .gmii_txd(gmii_txd),
        .gmii_tx_en(gmii_tx_en),
        .gmii_tx_er(gmii_tx_er),
        .gmii_rxd(),
        .gmii_rx_dv(),
        .gmii_rx_er(),
        .mii_tx_clk_out(),
        .tx_busy(tx_busy),
        .tx_fifo_level(),
        .dbg_tx_fifo_empty(),
        .dbg_rx_prog_empty(),
        .dbg_rx_rd_empty(),
        .dbg_rx_reading(),
        .dbg_rx_frames_pending()
    );

    reg  [7:0] tx_data;
    reg        tx_valid = 0;
    reg        tx_last  = 0;
    wire       tx_ready;

    eth_mac_tx u_mac_tx (
        .clk(clk),
        .rst_n(rst_n),
        .tx_start_ok(~tx_busy),
        .gmii_txd(gmii_txd),
        .gmii_tx_en(gmii_tx_en),
        .gmii_tx_er(gmii_tx_er),
        .s_axis_tdata(tx_data),
        .s_axis_tvalid(tx_valid),
        .s_axis_tready(tx_ready),
        .s_axis_tkeep(1'b1),
        .s_axis_tlast(tx_last),
        .tx_active()
    );

    localparam FRAME_LEN = 74;
    reg [7:0] frame [0:FRAME_LEN-1];
    integer i;
    initial begin
        frame[0] = 8'hFF; frame[1] = 8'hFF; frame[2] = 8'hFF;
        frame[3] = 8'hFF; frame[4] = 8'hFF; frame[5] = 8'hFF;
        frame[6] = 8'h02; frame[7] = 8'h00; frame[8] = 8'h00;
        frame[9] = 8'h00; frame[10] = 8'h00; frame[11] = 8'h01;
        frame[12] = 8'h08; frame[13] = 8'h00;
        for (i = 14; i < FRAME_LEN; i = i + 1)
            frame[i] = i[7:0];
    end

    integer tx_idx;
    initial begin
        @(posedge rst_n);
        #500;
        @(posedge clk);
        tx_valid <= 1'b1;
        tx_data  <= frame[0];
        for (tx_idx = 1; tx_idx < FRAME_LEN; tx_idx = tx_idx + 1) begin
            @(posedge clk);
            while (!tx_ready) @(posedge clk);
            tx_data <= frame[tx_idx];
            tx_last <= (tx_idx == FRAME_LEN - 1);
        end
        @(posedge clk);
        while (!tx_ready) @(posedge clk);
        tx_valid <= 1'b0;
        tx_last  <= 1'b0;
    end

    reg [7:0] gmii_buf [0:127];
    reg [7:0] mii_buf  [0:127];
    integer gmii_count = 0;
    integer mii_count = 0;
    integer mismatch_count = 0;
    integer cmp_idx;
    reg prev_mii_tx_en = 0;
    reg nib_sel = 0;
    reg [3:0] low_nibble = 0;

    always @(posedge clk) begin
        if (gmii_tx_en && gmii_count < 128) begin
            gmii_buf[gmii_count] <= gmii_txd;
            gmii_count <= gmii_count + 1;
        end
    end

    always @(posedge mii_clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_mii_tx_en <= 1'b0;
            nib_sel        <= 1'b0;
            low_nibble     <= 4'd0;
            mii_count      <= 0;
        end else begin
            prev_mii_tx_en <= mii_tx_en;

            if (!prev_mii_tx_en && mii_tx_en) begin
                nib_sel   <= 1'b0;
                mii_count <= 0;
            end

            if (mii_tx_en) begin
                if (!nib_sel) begin
                    low_nibble <= mii_txd;
                    nib_sel    <= 1'b1;
                end else begin
                    if (mii_count < 128)
                        mii_buf[mii_count] <= {mii_txd, low_nibble};
                    mii_count <= mii_count + 1;
                    nib_sel   <= 1'b0;
                end
            end
        end
    end

    initial begin
        $dumpfile("tb_mii_tx_bridge.vcd");
        $dumpvars(0, tb_mii_tx_bridge);

        #300000;

        $display("GMII bytes: %0d", gmii_count);
        $display("MII reconstructed bytes: %0d", mii_count);

        if (gmii_count != mii_count) begin
            $display("FAIL: byte count mismatch");
            mismatch_count = mismatch_count + 1;
        end

        for (cmp_idx = 0; cmp_idx < gmii_count && cmp_idx < mii_count; cmp_idx = cmp_idx + 1) begin
            if (gmii_buf[cmp_idx] !== mii_buf[cmp_idx]) begin
                $display("FAIL: byte %0d mismatch gmii=%02x mii=%02x",
                         cmp_idx, gmii_buf[cmp_idx], mii_buf[cmp_idx]);
                mismatch_count = mismatch_count + 1;
            end
        end

        if (!gmii_tx_er && mismatch_count == 0) begin
            $display("MII TX bridge: 1 tests passed");
            $display("ALL TESTS PASSED");
        end else
            $display("TESTS FAILED");

        $finish;
    end

endmodule
