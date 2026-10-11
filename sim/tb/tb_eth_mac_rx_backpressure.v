// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_eth_mac_rx_backpressure.v - RX AXI4-Stream backpressure regression
// Also checks the per-frame stat pulses with the RX FIFO held full: every
// frame for us ends in exactly one of stat_done (delivered, possibly
// truncated with stat_err_overflow) or stat_drop (dropped whole), and a frame
// for another MAC in neither.
// =============================================================================
`timescale 1ns / 1ps

module tb_eth_mac_rx_backpressure;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst_n = 0;

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

    wire [7:0] rx_tdata;
    wire       rx_tvalid;
    reg        rx_tready;
    wire       rx_tlast;
    wire       rx_terror;
    wire       rx_tsof;

    wire stat_done;
    wire stat_err_overflow;
    wire stat_drop;

    eth_mac_rx u_rx (
        .clk              (clk),
        .rst_n            (rst_n),
        .gmii_rxd         (lb_rxd),
        .gmii_rx_dv       (lb_rx_dv),
        .gmii_rx_er       (lb_rx_er),
        .our_mac          (48'hFF_FF_FF_FF_FF_FF),
        .promisc          (1'b0),
        .passthrough      (1'b0),
        .jumbo_en         (1'b1),
        .mcast_hash_table (64'd0),
        .m_axis_tdata     (rx_tdata),
        .m_axis_tvalid    (rx_tvalid),
        .m_axis_tready    (rx_tready),
        .m_axis_tlast     (rx_tlast),
        .m_axis_terror    (rx_terror),
        .m_axis_tsof      (rx_tsof),
        .stat_done         (stat_done),
        .stat_len          (),
        .stat_err_fcs      (),
        .stat_err_align    (),
        .stat_err_overflow (stat_err_overflow),
        .stat_err_oversize (),
        .stat_is_bcast     (),
        .stat_is_mcast     (),
        .stat_drop         (stat_drop)
    );


    localparam FRAME_LEN = 74;
    reg [7:0] frame [0:FRAME_LEN-1];
    reg [7:0] rx_buf [0:FRAME_LEN-1];
    integer i;
    integer rx_count;
    reg     last_rx_error;
    integer pass_cnt;
    integer fail_cnt;

    // Stat pulse and TLAST handshake tallies (cleared by the stimulus)
    integer n_done;
    integer n_overflow;
    integer n_drop;
    integer n_tlast;
    integer n_tlast_err;

    always @(posedge clk) begin
        if (rst_n) begin
            if (stat_done)                      n_done     = n_done + 1;
            if (stat_done && stat_err_overflow) n_overflow = n_overflow + 1;
            if (stat_drop)                      n_drop     = n_drop + 1;
            if (stat_done && stat_drop) begin
                $display("FAIL: stat_done and stat_drop in the same cycle");
                fail_cnt = fail_cnt + 1;
            end
            if (rx_tvalid && rx_tready && rx_tlast) begin
                n_tlast = n_tlast + 1;
                if (rx_terror) n_tlast_err = n_tlast_err + 1;
            end
        end
    end

    task check_int;
        input [255:0] name;
        input integer actual;
        input integer expected;
        begin
            if (actual == expected) begin
                $display("PASS: %0s = %0d", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = %0d, expected %0d", name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    initial begin
        frame[0] = 8'hFF; frame[1] = 8'hFF; frame[2] = 8'hFF;
        frame[3] = 8'hFF; frame[4] = 8'hFF; frame[5] = 8'hFF;
        frame[6] = 8'h02; frame[7] = 8'h00; frame[8] = 8'h00;
        frame[9] = 8'h00; frame[10] = 8'h00; frame[11] = 8'h01;
        frame[12] = 8'h08; frame[13] = 8'h00;
        for (i = 14; i < FRAME_LEN; i = i + 1)
            frame[i] = i[7:0];
    end

    task send_frame;
        integer k;
        begin
            for (k = 0; k < FRAME_LEN; k = k + 1) begin
                @(negedge clk);
                tx_tdata  = frame[k];
                tx_tvalid = 1'b1;
                tx_tlast  = (k == FRAME_LEN - 1);
                @(posedge clk);
                while (!tx_tready) @(posedge clk);
            end
            @(negedge clk);
            tx_tvalid = 1'b0;
            tx_tlast  = 1'b0;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_count <= 0;
            last_rx_error <= 1'b0;
        end else if (rx_tvalid && rx_tready) begin
            if (rx_count < FRAME_LEN)
                rx_buf[rx_count] <= rx_tdata;
            rx_count <= rx_count + 1;
            if (rx_tlast)
                last_rx_error <= rx_terror;
        end
    end

    initial begin
        $dumpfile("tb_eth_mac_rx_backpressure.vcd");
        $dumpvars(0, tb_eth_mac_rx_backpressure);

        pass_cnt = 0;
        fail_cnt = 0;
        tx_tdata = 8'd0;
        tx_tvalid = 1'b0;
        tx_tlast = 1'b0;
        rx_tready = 1'b0;

        #100;
        rst_n = 1;
        #100;

        fork
            begin
                send_frame();
            end
            begin
                wait (rx_tvalid);
                repeat (20) @(posedge clk);
                // Drive rx_tready on negedge to avoid a posedge race with the
                // rx_count sampling always block (could otherwise count one
                // phantom cycle where rx_tready was just set but axis_pop
                // had already evaluated to 0).
                @(negedge clk);
                rx_tready = 1'b1;
            end
        join

        repeat (200) @(posedge clk);

        if (rx_count == FRAME_LEN) begin
            $display("PASS: received %0d payload bytes after stall", rx_count);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: received %0d payload bytes, expected %0d", rx_count, FRAME_LEN);
            fail_cnt = fail_cnt + 1;
        end

        begin : check_payload
            integer bad;
            bad = 0;
            for (i = 0; i < FRAME_LEN; i = i + 1)
                if (rx_buf[i] !== frame[i])
                    bad = 1;
            if (!bad) begin
                $display("PASS: stalled RX data integrity");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: stalled RX data mismatch");
                fail_cnt = fail_cnt + 1;
            end
        end

        if (!last_rx_error) begin
            $display("PASS: no RX error after backpressure");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: RX error asserted after backpressure");
            fail_cnt = fail_cnt + 1;
        end

        // -----------------------------------------------------------------
        // FIFO held full: N frames for us, tready low throughout. Each frame
        // stores FRAME_LEN bytes (FCS stripped), so FULL_FRAMES fit below the
        // high-water mark (depth - 4), the next starts with room and is
        // truncated, and the rest are dropped whole.
        // -----------------------------------------------------------------
        begin : fifo_full
            integer f;
            integer full_frames;
            localparam N_FRAMES = 32;
            full_frames = (2048 - 4) / FRAME_LEN;   // 27 for FRAME_LEN = 74

            @(negedge clk);
            rx_tready = 1'b0;
            n_done = 0; n_overflow = 0; n_drop = 0; n_tlast = 0; n_tlast_err = 0;

            for (f = 0; f < N_FRAMES; f = f + 1)
                send_frame();
            repeat (100) @(posedge clk);

            check_int("done + drop (FIFO full)", n_done + n_drop, N_FRAMES);
            check_int("stat_done (FIFO full)", n_done, full_frames + 1);
            check_int("stat_err_overflow (FIFO full)", n_overflow, 1);
            check_int("stat_drop (FIFO full)", n_drop, N_FRAMES - full_frames - 1);

            // A frame for another MAC while the FIFO is full: no stat at all
            frame[0] = 8'h02; frame[1] = 8'h00; frame[2] = 8'h00;
            frame[3] = 8'h00; frame[4] = 8'h00; frame[5] = 8'h99;
            n_done = 0; n_drop = 0;
            send_frame();
            repeat (100) @(posedge clk);
            check_int("done + drop (other MAC)", n_done + n_drop, 0);
            for (f = 0; f < 6; f = f + 1)
                frame[f] = 8'hFF;

            // Drain: the delivered frames come out, the truncated one with
            // terror, and nothing of the dropped ones.
            @(negedge clk);
            rx_tready = 1'b1;
            repeat (3000) @(posedge clk);
            check_int("TLAST handshakes after drain", n_tlast, full_frames + 1);
            check_int("terror TLASTs after drain", n_tlast_err, 1);
        end

        if (fail_cnt == 0) begin
            $display("ETH-MAC-RX-BACKPRESSURE: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("TESTS FAILED");
        end

        $finish;
    end

endmodule
