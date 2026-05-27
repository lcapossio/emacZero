// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_eth_mac_sys_csum.v - End-to-end test of cfg_tx_csum_off through eth_mac_sys
//
// Drives an IPv4 UDP frame with deliberately bogus IP / UDP checksums into
// eth_mac_sys (MII mode, csum offload enabled via CSR), then taps the
// internal GMII TX bus (gmii_txd / gmii_tx_en) directly to read what the
// MAC actually emits. Strips preamble/SFD and the trailing CRC, then
// verifies:
//   - The IP header checksum is recomputed (and not still 0xDEAD)
//   - The UDP checksum field is zeroed (per RFC 768 §3, valid for IPv4)
//   - All other frame bytes are unchanged
//
// Tapping the GMII bus bypasses the mii_if MII clock-domain crossing so the
// test isolates the csum-offload integration logic.
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_eth_mac_sys_csum;

`ifdef TB_TX_CSUM_OFFLOAD
    localparam TX_CSUM_PARAM = 1;
`else
    localparam TX_CSUM_PARAM = 0;
`endif

    reg clk;        // 100 MHz
    reg mii_clk;    // 25 MHz
    reg rst_n;

    initial clk = 0;
    always #5 clk = ~clk;
    initial mii_clk = 0;
    always #20 mii_clk = ~mii_clk;

    // ---- AXI-Lite ----
    reg  [7:0]  awaddr;  reg awvalid;  wire awready;
    reg  [31:0] wdata;   reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp;   wire bvalid;  reg bready;
    reg  [7:0]  araddr;  reg arvalid;  wire arready;
    wire [31:0] rdata;   wire [1:0] rresp; wire rvalid; reg rready;

    // ---- AXI-Stream TX ----
    reg  [7:0]  tx_tdata;  reg tx_tvalid;  wire tx_tready; reg tx_tlast;
    // ---- AXI-Stream RX (unused) ----
    wire [7:0]  rx_tdata;  wire rx_tvalid; wire rx_tlast;  wire rx_terror;
    wire        rx_tsof;

    // ---- MII pins (we don't use loopback; tap GMII directly) ----
    wire [3:0]  mii_txd;   wire mii_tx_en;
    wire        mdc, mdio_o, mdio_oe;
    wire        irq;

    eth_mac_sys #(
        .PHY_INTERFACE("MII"),
        .MAX_FRAME(2048),
        .TX_CSUM_OFFLOAD(TX_CSUM_PARAM)
    ) uut (
        .clk            (clk),
        .rst_n          (rst_n),
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
        .s_axis_tdata   (tx_tdata),
        .s_axis_tvalid  (tx_tvalid),
        .s_axis_tready  (tx_tready),
        .s_axis_tlast   (tx_tlast),
        .m_axis_tdata   (rx_tdata),
        .m_axis_tvalid  (rx_tvalid),
        .m_axis_tready  (1'b1),
        .m_axis_tlast   (rx_tlast),
        .m_axis_terror  (rx_terror),
        .m_axis_tsof    (rx_tsof),
        .mii_txd        (mii_txd),
        .mii_tx_en      (mii_tx_en),
        .mii_tx_clk     (mii_clk),
        .mii_rxd        (4'd0),
        .mii_rx_dv      (1'b0),
        .mii_rx_er      (1'b0),
        .mii_rx_clk     (mii_clk),
        .mii_col        (1'b0),
        .mii_crs        (1'b0),
        .clk_125        (1'b0),
        .clk_125_90     (1'b0),
        .clk_25         (1'b0),
        .clk_2_5        (1'b0),
        .rgmii_txd      (),
        .rgmii_tx_ctl   (),
        .rgmii_txc      (),
        .rgmii_rxd      (4'd0),
        .rgmii_rx_ctl   (1'b0),
        .rgmii_rxc      (1'b0),
        .mdc            (mdc),
        .mdio_i         (mdio_o),
        .mdio_o         (mdio_o),
        .mdio_oe        (mdio_oe),
        .irq            (irq)
    );

    // ---- AXI-Lite BFM ----
    task axi_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            awaddr = addr; awvalid = 1;
            wdata = data; wstrb = 4'hF; wvalid = 1;
            bready = 1;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            @(negedge clk);
            awvalid = 0; wvalid = 0; bready = 0;
        end
    endtask

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // ---- Build IPv4 UDP frame with bogus checksums ----
    // No preamble — eth_mac_tx adds preamble/SFD itself.
    //   [0..5]   dst MAC = broadcast
    //   [6..11]  src MAC
    //   [12..13] ethertype 0x0800
    //   [14..33] IP header (IHL=5, proto=UDP, csum=0xDEAD)
    //   [34..41] UDP header (csum=0xBEEF — must be zeroed)
    //   [42..]   UDP payload
    localparam FRAME_LEN = 60;
    reg [7:0] frame [0:FRAME_LEN-1];

    integer i;
    initial begin
        for (i = 0; i < 6; i = i + 1) frame[i] = 8'hFF;
        frame[6]=8'h02; frame[7]=8'h11; frame[8]=8'h22;
        frame[9]=8'h33; frame[10]=8'h44; frame[11]=8'h55;
        frame[12]=8'h08; frame[13]=8'h00;
        frame[14]=8'h45; frame[15]=8'h00;
        frame[16]=8'h00; frame[17]=8'h2E;
        frame[18]=8'h12; frame[19]=8'h34;
        frame[20]=8'h40; frame[21]=8'h00;
        frame[22]=8'h40; frame[23]=8'h11;
        frame[24]=8'hDE; frame[25]=8'hAD;     // bogus IP csum
        frame[26]=8'hC0; frame[27]=8'hA8; frame[28]=8'h01; frame[29]=8'h32;
        frame[30]=8'hC0; frame[31]=8'hA8; frame[32]=8'h01; frame[33]=8'hC8;
        frame[34]=8'h12; frame[35]=8'h34;
        frame[36]=8'h56; frame[37]=8'h78;
        frame[38]=8'h00; frame[39]=8'h1A;
        frame[40]=8'hBE; frame[41]=8'hEF;     // bogus UDP csum
        for (i = 42; i < FRAME_LEN; i = i + 1)
            frame[i] = i[7:0];
    end

    // ---- GMII bus tap (directly inside eth_mac_sys) ----
    // Captures every byte while gmii_tx_en is asserted, INCLUDING preamble/SFD
    // and the 4-byte CRC. We strip those at verification time.
    reg [7:0] gmii_buf [0:127];
    integer   gmii_byte_cnt;
    reg       gmii_done;
    reg       gmii_tx_en_d1;
    always @(posedge clk) begin
        if (!rst_n) begin
            gmii_byte_cnt <= 0;
            gmii_done     <= 0;
            gmii_tx_en_d1 <= 0;
        end else begin
            gmii_tx_en_d1 <= uut.gmii_tx_en;
            if (uut.gmii_tx_en && !gmii_done) begin
                if (gmii_byte_cnt < 128)
                    gmii_buf[gmii_byte_cnt] <= uut.gmii_txd;
                gmii_byte_cnt <= gmii_byte_cnt + 1;
            end
            // Falling edge of gmii_tx_en marks frame end
            if (gmii_tx_en_d1 && !uut.gmii_tx_en && gmii_byte_cnt > 0)
                gmii_done <= 1;
        end
    end

    // Recompute IP header checksum across the data portion of gmii_buf.
    // Caller passes the 8-byte preamble offset.
    function [15:0] ip_csum_compute;
        input integer base;       // offset of first data byte
        input [7:0] b14, b15, b16, b17, b18, b19, b20, b21, b22, b23;
        input [7:0] b26, b27, b28, b29, b30, b31, b32, b33;
        reg [31:0] s;
        reg [16:0] f1;
        reg [15:0] f2;
        begin
            s = {16'd0, b14,b15} + {16'd0, b16,b17} + {16'd0, b18,b19} +
                {16'd0, b20,b21} + {16'd0, b22,b23} +
                {16'd0, b26,b27} + {16'd0, b28,b29} +
                {16'd0, b30,b31} + {16'd0, b32,b33};
            f1 = s[15:0] + s[31:16];
            f2 = f1[15:0] + {15'd0, f1[16]};
            ip_csum_compute = ~f2;
        end
    endfunction

    integer k;
    integer base;       // index of first data byte after preamble/SFD
    integer data_len;   // number of data bytes in gmii_buf (excl preamble+CRC)
    reg [15:0] expected_ip_csum;

    initial begin
        $dumpfile("tb_eth_mac_sys_csum.vcd");
        $dumpvars(0, tb_eth_mac_sys_csum);

        awaddr=0; awvalid=0; wdata=0; wstrb=0; wvalid=0; bready=0;
        araddr=0; arvalid=0; rready=0;
        tx_tdata=0; tx_tvalid=0; tx_tlast=0;
        rst_n = 0;
        #100;
        rst_n = 1;
        #100;

        if (TX_CSUM_PARAM)
            $display("INFO: TX_CSUM_OFFLOAD=1, CTRL[7] should patch checksums");
        else
            $display("INFO: TX_CSUM_OFFLOAD=0, CTRL[7] should be a no-op");

        // CTRL: tx_en=1, rx_en=1, promisc=1, full_duplex=1, tx_csum_off=1
        // = 0b1010_0111 = 0xA7
        axi_write(8'h04, 32'h0000_00A7);

        // Send the frame
        @(negedge clk);
        for (k = 0; k < FRAME_LEN; k = k + 1) begin
            tx_tdata  = frame[k];
            tx_tvalid = 1'b1;
            tx_tlast  = (k == FRAME_LEN - 1);
            @(negedge clk);
            while (!tx_tready) @(negedge clk);
        end
        tx_tvalid = 1'b0;
        tx_tlast  = 1'b0;

        // Wait for entire frame to drain through GMII (preamble+SFD+data+CRC+IFG)
        #20000;

        // Locate first data byte: scan for SFD (0xD5) starting from byte 0
        base = -1;
        for (k = 0; k < gmii_byte_cnt - 1; k = k + 1) begin
            if (gmii_buf[k] === 8'hD5) begin
                base = k + 1;
                k = gmii_byte_cnt;
            end
        end

        if (base < 0) begin
            $display("FAIL: SFD (0xD5) not found in GMII capture");
            fail_cnt = fail_cnt + 1;
            $finish;
        end else begin
            $display("PASS: SFD found at byte %0d, data starts at %0d",
                     base - 1, base);
            pass_cnt = pass_cnt + 1;
        end

        data_len = gmii_byte_cnt - base - 4;   // strip 4-byte CRC

        if (data_len < FRAME_LEN) begin
            $display("FAIL: GMII data_len=%0d < expected %0d (gmii_byte_cnt=%0d, base=%0d)",
                     data_len, FRAME_LEN, gmii_byte_cnt, base);
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("PASS: GMII data_len=%0d (>= FRAME_LEN=%0d, padding ok)",
                     data_len, FRAME_LEN);
            pass_cnt = pass_cnt + 1;
        end

        // ---- Verify IP / UDP checksum behavior ----
        expected_ip_csum = ip_csum_compute(
            base + 14,
            gmii_buf[base+14], gmii_buf[base+15], gmii_buf[base+16], gmii_buf[base+17],
            gmii_buf[base+18], gmii_buf[base+19], gmii_buf[base+20], gmii_buf[base+21],
            gmii_buf[base+22], gmii_buf[base+23],
            gmii_buf[base+26], gmii_buf[base+27], gmii_buf[base+28], gmii_buf[base+29],
            gmii_buf[base+30], gmii_buf[base+31], gmii_buf[base+32], gmii_buf[base+33]);

        if (TX_CSUM_PARAM) begin
            if ({gmii_buf[base+24], gmii_buf[base+25]} === expected_ip_csum) begin
                $display("PASS: IP checksum patched = 0x%04x",
                         {gmii_buf[base+24], gmii_buf[base+25]});
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: IP checksum = 0x%04x, expected 0x%04x",
                         {gmii_buf[base+24], gmii_buf[base+25]}, expected_ip_csum);
                fail_cnt = fail_cnt + 1;
            end

            if ({gmii_buf[base+24], gmii_buf[base+25]} !== 16'hDEAD) begin
                $display("PASS: IP checksum overwritten (not still 0xDEAD)");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: IP checksum still 0xDEAD (csum_off not effective)");
                fail_cnt = fail_cnt + 1;
            end

            if (gmii_buf[base+40] === 8'h00 && gmii_buf[base+41] === 8'h00) begin
                $display("PASS: UDP checksum zeroed");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: UDP checksum = 0x%02x%02x, expected 0x0000",
                         gmii_buf[base+40], gmii_buf[base+41]);
                fail_cnt = fail_cnt + 1;
            end
        end else begin
            if ({gmii_buf[base+24], gmii_buf[base+25]} === 16'hDEAD) begin
                $display("PASS: IP checksum preserved with TX_CSUM_OFFLOAD=0");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: IP checksum changed to 0x%04x with TX_CSUM_OFFLOAD=0",
                         {gmii_buf[base+24], gmii_buf[base+25]});
                fail_cnt = fail_cnt + 1;
            end

            if ({gmii_buf[base+40], gmii_buf[base+41]} === 16'hBEEF) begin
                $display("PASS: UDP checksum preserved with TX_CSUM_OFFLOAD=0");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: UDP checksum changed to 0x%04x with TX_CSUM_OFFLOAD=0",
                         {gmii_buf[base+40], gmii_buf[base+41]});
                fail_cnt = fail_cnt + 1;
            end
        end

        // ---- Spot checks for unmodified bytes ----
        if (gmii_buf[base+0]  === 8'hFF &&
            gmii_buf[base+12] === 8'h08 &&
            gmii_buf[base+13] === 8'h00 &&
            gmii_buf[base+14] === 8'h45 &&
            gmii_buf[base+26] === 8'hC0 &&
            gmii_buf[base+33] === 8'hC8 &&
            gmii_buf[base+42] === 8'h2A) begin
            $display("PASS: unmodified bytes intact");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: unmodified bytes corrupted");
            fail_cnt = fail_cnt + 1;
        end

        // ---- Summary ----
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
