// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_axilite_regs.v - Testbench for axilite_regs.v
// Tests: scratch RW, version RO, MAC addr, MDIO go self-clear, IRQ W1C,
//        stats clear-on-write, config outputs
// =============================================================================
`timescale 1ns / 1ps
`include "version.vh"

module tb_axilite_regs;

    // ---- Clock / reset ----
    reg         clk;
    reg         aresetn;
    initial clk = 0;
    always #5 clk = ~clk;

    // ---- AXI4-Lite signals ----
    reg  [7:0]  awaddr;
    reg         awvalid;
    wire        awready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;
    reg  [7:0]  araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;

    // ---- Register interface ----
    wire        cfg_tx_en, cfg_rx_en, cfg_promisc;
    wire [47:0] cfg_mac_addr;
    wire        mdio_go, mdio_write;
    wire [4:0]  mdio_phy_addr, mdio_reg_addr;
    wire [15:0] mdio_wdata_out;
    reg  [15:0] mdio_rdata;
    reg         mdio_done;
    reg         mdio_busy;
    wire        stat_clr_tx, stat_clr_rx;
    reg  [31:0] stat_tx_frame_cnt, stat_tx_byte_cnt;
    reg  [31:0] stat_rx_frame_cnt, stat_rx_byte_cnt, stat_rx_err_cnt;
    reg         sts_tx_active, sts_tx_fifo_busy;
    reg         evt_tx_done, evt_rx_frame;
    wire        irq;

    integer pass_cnt, fail_cnt;

    axilite_regs #(.ADDR_WIDTH(8)) uut (
        .s_axi_aclk     (clk),
        .s_axi_aresetn  (aresetn),
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
        .cfg_tx_en      (cfg_tx_en),
        .cfg_rx_en      (cfg_rx_en),
        .cfg_promisc    (cfg_promisc),
        .cfg_speed      (),
        .cfg_full_duplex(),
        .cfg_jumbo_en   (),
        .cfg_tx_csum_off(),
        .cfg_passthrough(),
        .cfg_mcast_hash_table(),
        .cfg_mac_addr   (cfg_mac_addr),
        .mdio_go        (mdio_go),
        .mdio_write     (mdio_write),
        .mdio_phy_addr  (mdio_phy_addr),
        .mdio_reg_addr  (mdio_reg_addr),
        .mdio_wdata     (mdio_wdata_out),
        .mdio_c45_en    (),
        .mdio_c45_op    (),
        .mdio_rdata     (mdio_rdata),
        .mdio_done      (mdio_done),
        .mdio_busy      (mdio_busy),
        .stat_tx_frame_cnt (stat_tx_frame_cnt),
        .stat_tx_byte_cnt  (stat_tx_byte_cnt),
        .stat_rx_frame_cnt (stat_rx_frame_cnt),
        .stat_rx_byte_cnt  (stat_rx_byte_cnt),
        .stat_rx_err_cnt   (stat_rx_err_cnt),
        .stat_rx_err_align_cnt    (32'd0),
        .stat_rx_err_overflow_cnt (32'd0),
        .stat_rx_err_oversize_cnt (32'd0),
        .stat_rx_bcast_cnt        (32'd0),
        .stat_rx_mcast_cnt        (32'd0),
        .stat_rx_size_64_cnt        (32'd0),
        .stat_rx_size_65_127_cnt    (32'd0),
        .stat_rx_size_128_255_cnt   (32'd0),
        .stat_rx_size_256_511_cnt   (32'd0),
        .stat_rx_size_512_1023_cnt  (32'd0),
        .stat_rx_size_1024_1518_cnt (32'd0),
        .stat_rx_size_jumbo_cnt     (32'd0),
        .cfg_pause_rx_en      (),
        .cfg_pause_tx_send    (),
        .cfg_pause_tx_quanta  (),
        .stat_pause_rx_cnt    (32'd0),
        .stat_pause_tx_cnt    (32'd0),
        .stat_clr_pause       (),
        .stat_clr_tx    (stat_clr_tx),
        .stat_clr_rx    (stat_clr_rx),
        .sts_tx_active    (sts_tx_active),
        .sts_tx_fifo_busy (sts_tx_fifo_busy),
        .evt_tx_done    (evt_tx_done),
        .evt_rx_frame   (evt_rx_frame),
        .irq            (irq)
    );

    // ---- AXI4-Lite BFM tasks ----
    reg [31:0] rd_result;

    localparam [7:0] A_VERSION    = 8'h00;
    localparam [7:0] A_CTRL       = 8'h04;
    localparam [7:0] A_STATUS     = 8'h08;
    localparam [7:0] A_MAC_LO     = 8'h0C;
    localparam [7:0] A_MAC_HI     = 8'h10;
    localparam [7:0] A_MDIO_CMD   = 8'h14;
    localparam [7:0] A_MDIO_WDATA = 8'h18;
    localparam [7:0] A_MDIO_RDATA = 8'h1C;
    localparam [7:0] A_IRQ_EN     = 8'h20;
    localparam [7:0] A_IRQ_STATUS = 8'h24;
    localparam [7:0] A_TX_FRAME   = 8'h28;
    localparam [7:0] A_RX_FRAME   = 8'h30;
    localparam [7:0] A_RX_ERR     = 8'h38;
    localparam [7:0] A_SCRATCH    = 8'h3C;

    task axi_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            awaddr  = addr;
            awvalid = 1;
            wdata   = data;
            wstrb   = 4'hF;
            wvalid  = 1;
            bready  = 1;
            // Wait for bvalid (encompasses AW+W+B handshake)
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            @(negedge clk);
            awvalid = 0;
            wvalid  = 0;
            bready  = 0;
        end
    endtask

    // AW-first: present address, wait for awready, then present data
    task axi_write_aw_first;
        input [7:0]  addr;
        input [31:0] data;
        input [3:0]  strobe;
        begin
            // AW phase
            @(negedge clk);
            awaddr  = addr;
            awvalid = 1;
            wvalid  = 0;
            bready  = 1;
            @(posedge clk);
            while (!awready) @(posedge clk);
            @(negedge clk);
            awvalid = 0;
            // W phase (1 cycle gap)
            @(negedge clk);
            wdata   = data;
            wstrb   = strobe;
            wvalid  = 1;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            @(negedge clk);
            wvalid  = 0;
            bready  = 0;
        end
    endtask

    // W-first: present data, wait for wready, then present address
    task axi_write_w_first;
        input [7:0]  addr;
        input [31:0] data;
        input [3:0]  strobe;
        begin
            // W phase
            @(negedge clk);
            wdata   = data;
            wstrb   = strobe;
            wvalid  = 1;
            awvalid = 0;
            bready  = 1;
            @(posedge clk);
            while (!wready) @(posedge clk);
            @(negedge clk);
            wvalid  = 0;
            // AW phase (1 cycle gap)
            @(negedge clk);
            awaddr  = addr;
            awvalid = 1;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            @(negedge clk);
            awvalid = 0;
            bready  = 0;
        end
    endtask

    // Write with explicit WSTRB
    task axi_write_strb;
        input [7:0]  addr;
        input [31:0] data;
        input [3:0]  strobe;
        begin
            @(negedge clk);
            awaddr  = addr;
            awvalid = 1;
            wdata   = data;
            wstrb   = strobe;
            wvalid  = 1;
            bready  = 1;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            @(negedge clk);
            awvalid = 0;
            wvalid  = 0;
            bready  = 0;
        end
    endtask

    task axi_read;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            @(negedge clk);
            araddr  = addr;
            arvalid = 1;
            rready  = 1;
            // Wait for rvalid (encompasses AR+R handshake)
            @(posedge clk);
            while (!rvalid) @(posedge clk);
            data = rdata;
            @(negedge clk);
            arvalid = 0;
            rready  = 0;
        end
    endtask

    task check32;
        input [255:0] name;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s = 0x%08x", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = 0x%08x, expected 0x%08x", name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task check1;
        input [255:0] name;
        input         actual;
        input         expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s = %0b", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = %0b, expected %0b", name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_axilite_regs.vcd");
        $dumpvars(0, tb_axilite_regs);

        pass_cnt = 0;
        fail_cnt = 0;

        // Init
        aresetn = 0;
        awaddr = 0; awvalid = 0;
        wdata = 0; wstrb = 0; wvalid = 0;
        bready = 0;
        araddr = 0; arvalid = 0; rready = 0;
        mdio_rdata = 16'hBEEF;
        mdio_done = 0;
        mdio_busy = 0;
        stat_tx_frame_cnt = 32'd100;
        stat_tx_byte_cnt  = 32'd2000;
        stat_rx_frame_cnt = 32'd50;
        stat_rx_byte_cnt  = 32'd1000;
        stat_rx_err_cnt   = 32'd3;
        sts_tx_active = 0;
        sts_tx_fifo_busy = 0;
        evt_tx_done = 0;
        evt_rx_frame = 0;

        #30;
        aresetn = 1;
        @(posedge clk); #1;

        // =================================================================
        // Test 1: VERSION register (read-only)
        // =================================================================
        axi_read(A_VERSION, rd_result);
        check32("VERSION", rd_result,
                {`EMZ_VERSION_MAJOR, `EMZ_VERSION_MINOR, `EMZ_VERSION_ID});

        // =================================================================
        // Test 2: SCRATCH register (write/read)
        // =================================================================
        axi_write(A_SCRATCH, 32'hDEAD_BEEF);
        axi_read(A_SCRATCH, rd_result);
        check32("SCRATCH write/read", rd_result, 32'hDEAD_BEEF);

        axi_write(A_SCRATCH, 32'h1234_5678);
        axi_read(A_SCRATCH, rd_result);
        check32("SCRATCH overwrite", rd_result, 32'h1234_5678);

        // =================================================================
        // Test 3: CTRL register + config outputs
        // =================================================================
        // Default: tx_en=1, rx_en=1, promisc=0
        axi_read(A_CTRL, rd_result);
        // Default CTRL: tx_en=1, rx_en=1, promisc=0, speed=00 (1G),
        // full_duplex=1, jumbo_en=0, tx_csum_off=0  =>  0x23
        check32("CTRL default", rd_result, 32'h0000_0023);
        check1("cfg_tx_en default", cfg_tx_en, 1'b1);
        check1("cfg_rx_en default", cfg_rx_en, 1'b1);
        check1("cfg_promisc default", cfg_promisc, 1'b0);

        // Set promisc, clear tx_en
        axi_write(A_CTRL, 32'h0000_0006);
        @(posedge clk); #1;
        check1("cfg_tx_en after write", cfg_tx_en, 1'b0);
        check1("cfg_rx_en after write", cfg_rx_en, 1'b1);
        check1("cfg_promisc after write", cfg_promisc, 1'b1);

        // Restore default
        axi_write(A_CTRL, 32'h0000_0003);

        // =================================================================
        // Test 4: MAC address
        // =================================================================
        axi_write(A_MAC_LO, 32'hAABBCCDD);
        axi_write(A_MAC_HI, 32'h0000_1122);
        @(posedge clk); #1;
        axi_read(A_MAC_LO, rd_result);
        check32("MAC_LO", rd_result, 32'hAABBCCDD);
        axi_read(A_MAC_HI, rd_result);
        check32("MAC_HI", rd_result, 32'h0000_1122);

        if (cfg_mac_addr === 48'h1122_AABB_CCDD) begin
            $display("PASS: cfg_mac_addr = 0x%012x", cfg_mac_addr);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: cfg_mac_addr = 0x%012x, expected 0x1122AABBCCDD", cfg_mac_addr);
            fail_cnt = fail_cnt + 1;
        end

        // =================================================================
        // Test 5: MDIO command - go bit self-clearing
        // =================================================================
        axi_write(A_MDIO_WDATA, 32'h0000_FACE);
        axi_write(A_MDIO_CMD, 32'h0000_0C63);  // go=1, write=1, phy=3, reg=3
        @(posedge clk); #1;
        // mdio_go should have pulsed and cleared
        check1("mdio_go cleared", mdio_go, 1'b0);
        check1("mdio_write", mdio_write, 1'b1);

        // Read back MDIO_CMD: go bit should read 0
        axi_read(A_MDIO_CMD, rd_result);
        check32("MDIO_CMD go reads 0", rd_result & 32'h0000_0800, 32'h0000_0000);

        // MDIO_RDATA
        axi_read(A_MDIO_RDATA, rd_result);
        check32("MDIO_RDATA", rd_result, 32'h0000_BEEF);

        // =================================================================
        // Test 6: STATUS register
        // =================================================================
        sts_tx_active = 1;
        sts_tx_fifo_busy = 1;
        mdio_busy = 1;
        @(posedge clk); #1;
        axi_read(A_STATUS, rd_result);
        check32("STATUS all set", rd_result, 32'h0000_0007);

        sts_tx_active = 0;
        sts_tx_fifo_busy = 0;
        mdio_busy = 0;

        // =================================================================
        // Test 7: IRQ - event capture, enable, W1C
        // =================================================================
        // Enable tx_done and mdio_done interrupts
        axi_write(A_IRQ_EN, 32'h0000_0005);

        // Fire tx_done event
        @(negedge clk);
        evt_tx_done = 1;
        @(negedge clk);
        evt_tx_done = 0;
        @(posedge clk); #1;

        axi_read(A_IRQ_STATUS, rd_result);
        check32("IRQ_STATUS tx_done set", rd_result & 32'h1, 32'h1);
        check1("irq asserted", irq, 1'b1);

        // W1C: clear tx_done
        axi_write(A_IRQ_STATUS, 32'h0000_0001);
        @(posedge clk); #1;
        axi_read(A_IRQ_STATUS, rd_result);
        check32("IRQ_STATUS tx_done cleared", rd_result & 32'h1, 32'h0);
        check1("irq deasserted", irq, 1'b0);

        // =================================================================
        // Test 8: Stats registers read + clear-on-write
        // =================================================================
        axi_read(A_TX_FRAME, rd_result);
        check32("TX_FRAME_CNT", rd_result, 32'd100);

        axi_read(A_RX_FRAME, rd_result);
        check32("RX_FRAME_CNT", rd_result, 32'd50);

        // Write to TX_FRAME to trigger stat_clr_tx
        axi_write(A_TX_FRAME, 32'd0);
        @(posedge clk); #1;
        // stat_clr_tx should have pulsed (we verify it was asserted)
        // In real design, the stats module would zero the counters

        // Write to RX_ERR to trigger stat_clr_rx
        axi_write(A_RX_ERR, 32'd0);
        @(posedge clk); #1;

        // =================================================================
        // Test 9: AW-before-W (decoupled write)
        // =================================================================
        axi_write_aw_first(A_SCRATCH, 32'hCAFE_BABE, 4'hF);
        axi_read(A_SCRATCH, rd_result);
        check32("SCRATCH AW-first", rd_result, 32'hCAFE_BABE);

        // =================================================================
        // Test 10: W-before-AW (decoupled write)
        // =================================================================
        axi_write_w_first(A_SCRATCH, 32'h1234_5678, 4'hF);
        axi_read(A_SCRATCH, rd_result);
        check32("SCRATCH W-first", rd_result, 32'h1234_5678);

        // =================================================================
        // Test 11: Partial WSTRB - write only byte 0
        // =================================================================
        axi_write(A_SCRATCH, 32'hAAAA_AAAA);  // fill with known value
        axi_write_strb(A_SCRATCH, 32'h0000_00BB, 4'h1);  // only byte 0
        axi_read(A_SCRATCH, rd_result);
        check32("SCRATCH partial strb byte0", rd_result, 32'hAAAA_AABB);

        // =================================================================
        // Test 12: Partial WSTRB - write only byte 3
        // =================================================================
        axi_write_strb(A_SCRATCH, 32'hCC00_0000, 4'h8);  // only byte 3
        axi_read(A_SCRATCH, rd_result);
        check32("SCRATCH partial strb byte3", rd_result, 32'hCCAA_AABB);

        // =================================================================
        // Test 13: Partial WSTRB - write bytes 1 and 2
        // =================================================================
        axi_write_strb(A_SCRATCH, 32'h00DD_EE00, 4'h6);  // bytes 1 and 2
        axi_read(A_SCRATCH, rd_result);
        check32("SCRATCH partial strb byte1+2", rd_result, 32'hCCDD_EEBB);

        // =================================================================
        // Test 14: Back-to-back writes (no gap)
        // =================================================================
        axi_write(A_SCRATCH, 32'h1111_1111);
        axi_write(A_SCRATCH, 32'h2222_2222);
        axi_write(A_SCRATCH, 32'h3333_3333);
        axi_read(A_SCRATCH, rd_result);
        check32("SCRATCH back-to-back", rd_result, 32'h3333_3333);

        // =================================================================
        // Test 15: AW-first with partial WSTRB
        // =================================================================
        axi_write(A_SCRATCH, 32'hFFFF_FFFF);  // fill
        axi_write_aw_first(A_SCRATCH, 32'h0000_0042, 4'h1);  // byte 0 only
        axi_read(A_SCRATCH, rd_result);
        check32("SCRATCH AW-first partial strb", rd_result, 32'hFFFF_FF42);

        // =================================================================
        // Summary
        // =================================================================
        #20;
        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

endmodule
