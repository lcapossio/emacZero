// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_test_sequencer_mac.v - Unit test for the Arty test_sequencer enable step
//
// The sequencer's hard-wired boot timers are hundreds of millions of cycles,
// so the bench starts it directly in S_EN_MAC and checks the CSR writes from
// there, with a non-default OUR_MAC and a slow AXI-Lite slave:
//   T1: three writes, in order: MAC_LO = OUR_MAC[31:0], MAC_HI =
//       OUR_MAC[47:32], CTRL = 0x3 (tx_en, rx_en, promisc off)
//   T2: link down -> S_PRINT_DONE afterwards, no TX
//   T3: link up -> the gratuitous ARP goes out with OUR_MAC as Ethernet source
//       and sender hardware address
//   T4: running the step again (en_step back to 0) repeats the same writes
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_test_sequencer_mac;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    localparam [47:0] MAC = 48'h0A_1B_2C_3D_4E_5F;
    localparam [5:0]  S_EN_MAC     = 6'd27;
    localparam [5:0]  S_SEND_ARP   = 6'd29;
    localparam [5:0]  S_PRINT_DONE = 6'd38;

    wire [7:0]  awaddr;
    wire        awvalid;
    reg         awready = 1'b0;
    wire [31:0] wdata;
    wire [3:0]  wstrb;
    wire        wvalid;
    reg         wready = 1'b0;
    reg         bvalid = 1'b0;
    wire        bready;
    wire [7:0]  araddr;
    wire        arvalid;
    wire        rready;
    wire [7:0]  tx_tdata;
    wire        tx_tvalid;
    wire        tx_tlast;
    wire [7:0]  uart_data;
    wire        uart_valid;
    wire        link_up, phy_id_ok, tx_done, rx_done, arp_tx_active;

    test_sequencer #(.OUR_MAC(MAC)) u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .phy_rst_done  (1'b0),
        .m_axi_awaddr  (awaddr),
        .m_axi_awvalid (awvalid),
        .m_axi_awready (awready),
        .m_axi_wdata   (wdata),
        .m_axi_wstrb   (wstrb),
        .m_axi_wvalid  (wvalid),
        .m_axi_wready  (wready),
        .m_axi_bvalid  (bvalid),
        .m_axi_bready  (bready),
        .m_axi_araddr  (araddr),
        .m_axi_arvalid (arvalid),
        .m_axi_arready (1'b0),
        .m_axi_rdata   (32'd0),
        .m_axi_rvalid  (1'b0),
        .m_axi_rready  (rready),
        .tx_tdata      (tx_tdata),
        .tx_tvalid     (tx_tvalid),
        .tx_tready     (1'b1),
        .tx_tlast      (tx_tlast),
        .uart_data     (uart_data),
        .uart_valid    (uart_valid),
        .uart_busy     (1'b0),
        .link_up       (link_up),
        .phy_id_ok     (phy_id_ok),
        .tx_done       (tx_done),
        .rx_done       (rx_done),
        .arp_tx_active (arp_tx_active)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check;
        input [255:0] name;
        input cond;
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

    // ---- Slow AXI-Lite write slave: address and data accepted separately,
    // a few cycles apart, response a few cycles later ----
    reg [7:0]  wr_addr [0:7];
    reg [31:0] wr_data [0:7];
    reg [3:0]  wr_strb [0:7];
    integer    n_wr = 0;
    reg        got_aw = 1'b0, got_w = 1'b0;
    reg [7:0]  aw_q;
    reg [31:0] w_q;
    reg [3:0]  s_q;
    integer    dly = 0;

    always @(posedge clk) begin
        awready <= 1'b0;
        wready  <= 1'b0;
        if (bvalid && bready) bvalid <= 1'b0;
        if (awvalid && !got_aw && !awready && dly >= 2) begin
            awready <= 1'b1; got_aw <= 1'b1; aw_q <= awaddr;
        end
        if (wvalid && !got_w && !wready && dly >= 4) begin
            wready <= 1'b1; got_w <= 1'b1; w_q <= wdata; s_q <= wstrb;
        end
        if (awvalid || wvalid || got_aw || got_w) dly = dly + 1;
        if (got_aw && got_w && !bvalid && dly >= 7) begin
            if (n_wr < 8) begin
                wr_addr[n_wr] = aw_q; wr_data[n_wr] = w_q; wr_strb[n_wr] = s_q;
            end
            n_wr = n_wr + 1;
            bvalid <= 1'b1;
            got_aw <= 1'b0; got_w <= 1'b0; dly = 0;
        end
    end

    // ---- TX capture ----
    reg [7:0] txb [0:63];
    integer   n_tx = 0;
    always @(posedge clk) if (tx_tvalid) begin
        if (n_tx < 64) txb[n_tx] = tx_tdata;
        n_tx = n_tx + 1;
    end

    task run_en_mac;
        input lnk;
        integer t;
        begin
            @(negedge clk);
            u_dut.link_up = lnk;
            u_dut.state   = S_EN_MAC;
            t = 0;
            while (u_dut.state != S_PRINT_DONE && u_dut.state != S_SEND_ARP && t < 500) begin
                @(negedge clk);
                t = t + 1;
            end
        end
    endtask

    integer i;
    reg     ok;

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // T1/T2: link down
        n_wr = 0; n_tx = 0;
        run_en_mac(1'b0);
        check("T1 three CSR writes", n_wr == 3);
        check("T1 write 0 MAC_LO", wr_addr[0] == 8'h0C && wr_data[0] == MAC[31:0] && wr_strb[0] == 4'hF);
        check("T1 write 1 MAC_HI", wr_addr[1] == 8'h10 && wr_data[1] == {16'd0, MAC[47:32]} && wr_strb[1] == 4'hF);
        check("T1 write 2 CTRL = 0x3", wr_addr[2] == 8'h04 && wr_data[2] == 32'h3 && wr_strb[2] == 4'hF);
        check("T2 link down: S_PRINT_DONE", u_dut.state == S_PRINT_DONE);
        repeat (20) @(negedge clk);
        check("T2 link down: no TX", n_tx == 0);
        check("T2 no further writes", n_wr == 3);

        // T3/T4: link up, step runs again from en_step 0
        n_wr = 0; n_tx = 0;
        run_en_mac(1'b1);
        check("T4 rerun: three CSR writes", n_wr == 3);
        check("T4 rerun: same order", wr_addr[0] == 8'h0C && wr_addr[1] == 8'h10 && wr_addr[2] == 8'h04);
        check("T3 link up: S_SEND_ARP", u_dut.state == S_SEND_ARP);
        repeat (200) @(negedge clk);
        check("T3 ARP is 42 bytes", n_tx == 42);
        ok = 1'b1;
        for (i = 0; i < 6; i = i + 1) begin
            if (txb[6 + i]  != MAC[47 - 8*i -: 8]) ok = 1'b0;
            if (txb[22 + i] != MAC[47 - 8*i -: 8]) ok = 1'b0;
        end
        check("T3 ARP source and sender MAC = OUR_MAC", ok);

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
        $display("FAIL: timeout");
        $finish;
    end

endmodule
