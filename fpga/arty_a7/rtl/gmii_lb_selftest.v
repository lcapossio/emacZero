// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// gmii_lb_selftest.v - On-silicon GMII-path self-test for the Arty A7
//
// The Arty's DP83848J PHY is 10/100 MII only, so the board build never
// instantiates gmii_cdc. This block puts a second eth_mac_sys on the die with
// PHY_INTERFACE="GMII" and MAX_FRAME=9018, loops its GMII pins back in fabric
// on a 125 MHz MMCM clock, and runs generated traffic through the full path:
//
//   generator -> AXIS TX -> eth_mac_tx -> gmii_cdc TX -> gmii_if -> loopback
//   -> gmii_if -> gmii_cdc RX -> eth_mac_rx (FCS check) -> AXIS RX -> checker
//
// Payload lengths cycle through 46, 60, 1500, 1501, 4000, 4097, 8000 and 9000
// bytes (9000 = MAX_FRAME on the wire), so every eighth-frame group includes
// frames above the ~4083-byte size the old fixed RX CDC FIFO truncated.
// Every frame carries a 32-bit sequence number and a sequence-seeded byte
// pattern; the checker verifies length, header, pattern, terror and order.
//
// The loopback is lossless by construction: the TX framer runs at one byte per
// 100 MHz clk, so the RX reader (also one byte per clk) keeps up on average.
// Any rx_bad / rx_terror / seq_gap count is therefore a real failure.
//
// Control (ctrl, async - synchronized here):
//   [0] run   - generate traffic while high (the current frame completes)
//   [1] clear - hold high to zero all counters
// Status (sys_clk domain; stop traffic before reading for a coherent view):
//   [31:0]    tx_frames       frames handed to the MAC
//   [63:32]   rx_ok           frames received exact and clean
//   [95:64]   rx_ok_big       of those, frames longer than 4083 bytes
//   [127:96]  rx_bad          frames with wrong length / header / payload
//   [159:128] rx_terror       frames delivered with terror
//   [191:160] seq_gap         frames received out of sequence (lost/merged)
//   [207:192] max_ok_len      longest exact frame (bytes, FCS stripped)
//   [223:208] first_bad_len   length of the first bad frame
//   [239:224] first_bad_seq   sequence number [15:0] of the first bad frame
//   [240] init_done  [241] run (synced)  [242] mmcm_locked
//   [255:244] 12'hB0A        marker: this bitstream has the self-test
// =============================================================================
`ifdef SIM
`timescale 1ns / 1ps
`endif

module gmii_lb_selftest (
    input  wire         clk,        // 100 MHz system clock
    input  wire         rst_n,
    input  wire [1:0]   ctrl,
    output wire [255:0] status
);

    // =========================================================================
    // 125 MHz media clock (MMCM: 100 MHz x 10 / 8)
    // =========================================================================
    wire clk_125, mmcm_locked;
`ifdef SIM
    // Icarus has no MMCM: free-running behavioral 125 MHz, locked after reset.
    reg clk_125_sim = 1'b0;
    always #4 clk_125_sim = ~clk_125_sim;
    assign clk_125     = clk_125_sim;
    assign mmcm_locked = rst_n;
`else
    wire clk_125_mmcm, clkfb, clkfb_buf;

    MMCME2_BASE #(
        .CLKIN1_PERIOD   (10.0),
        .DIVCLK_DIVIDE   (1),
        .CLKFBOUT_MULT_F (10.0),
        .CLKOUT0_DIVIDE_F(8.0)
    ) u_mmcm (
        .CLKIN1  (clk),
        .CLKFBIN (clkfb_buf),
        .CLKFBOUT(clkfb),
        .CLKOUT0 (clk_125_mmcm),
        .LOCKED  (mmcm_locked),
        .PWRDWN  (1'b0),
        .RST     (!rst_n),
        .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(),
        .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(),
        .CLKOUT6()
    );
    BUFG u_bufg_fb  (.I(clkfb),        .O(clkfb_buf));
    BUFG u_bufg_125 (.I(clk_125_mmcm), .O(clk_125));
`endif

    // Reset the loopback MAC until the MMCM is locked.
    (* ASYNC_REG = "TRUE" *) reg [1:0] lock_s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lock_s <= 2'b00;
        else        lock_s <= {lock_s[0], mmcm_locked};
    end
    wire lb_rst_n = rst_n & lock_s[1];

    (* ASYNC_REG = "TRUE" *) reg [1:0] run_s, clr_s;
    always @(posedge clk or negedge lb_rst_n) begin
        if (!lb_rst_n) begin
            run_s <= 2'b00;
            clr_s <= 2'b00;
        end else begin
            run_s <= {run_s[0], ctrl[0]};
            clr_s <= {clr_s[0], ctrl[1]};
        end
    end
    wire run   = run_s[1];
    wire clear = clr_s[1];

    // =========================================================================
    // Loopback MAC
    // =========================================================================
    reg  [7:0]  awaddr;
    reg         awvalid, wvalid, bready;
    reg  [31:0] wdata;
    wire        awready, wready, bvalid;

    reg  [7:0]  tx_tdata;
    reg         tx_tvalid, tx_tlast;
    wire        tx_tready;

    wire [7:0]  m_rx_tdata;
    wire        m_rx_tvalid, m_rx_tlast, m_rx_terror, m_rx_tsof;

    wire [7:0]  gmii_txd;
    wire        gmii_tx_en, gmii_tx_er;

    eth_mac_sys #(
        .PHY_INTERFACE("GMII"),
        .MAX_FRAME    (9018)
    ) u_lb_mac (
        .clk            (clk),
        .rst_n          (lb_rst_n),
        .s_axi_awaddr   (awaddr),
        .s_axi_awvalid  (awvalid),
        .s_axi_awready  (awready),
        .s_axi_wdata    (wdata),
        .s_axi_wstrb    (4'hF),
        .s_axi_wvalid   (wvalid),
        .s_axi_wready   (wready),
        .s_axi_bresp    (),
        .s_axi_bvalid   (bvalid),
        .s_axi_bready   (bready),
        .s_axi_araddr   (8'd0),
        .s_axi_arvalid  (1'b0),
        .s_axi_arready  (),
        .s_axi_rdata    (),
        .s_axi_rresp    (),
        .s_axi_rvalid   (),
        .s_axi_rready   (1'b1),
        .s_axis_tdata   (tx_tdata),
        .s_axis_tvalid  (tx_tvalid),
        .s_axis_tready  (tx_tready),
        .s_axis_tlast   (tx_tlast),
        .m_axis_tdata   (m_rx_tdata),
        .m_axis_tvalid  (m_rx_tvalid),
        .m_axis_tready  (1'b1),
        .m_axis_tlast   (m_rx_tlast),
        .m_axis_terror  (m_rx_terror),
        .m_axis_tsof    (m_rx_tsof),
        .mii_txd        (),
        .mii_tx_en      (),
        .mii_tx_clk     (1'b0),
        .mii_rxd        (4'd0),
        .mii_rx_dv      (1'b0),
        .mii_rx_er      (1'b0),
        .mii_rx_clk     (1'b0),
        .mii_col        (1'b0),
        .mii_crs        (1'b0),
        .clk_125        (clk_125),
        .clk_125_90     (1'b0),
        .clk_25         (1'b0),
        .clk_2_5        (1'b0),
        .rgmii_txd      (),
        .rgmii_tx_ctl   (),
        .rgmii_txc      (),
        .rgmii_rxd      (4'd0),
        .rgmii_rx_ctl   (1'b0),
        .rgmii_rxc      (1'b0),
        // GMII pins looped back in fabric. The RX side samples on the same
        // 125 MHz clock, so the loop is a plain one-cycle register path.
        .phy_gmii_txd   (gmii_txd),
        .phy_gmii_tx_en (gmii_tx_en),
        .phy_gmii_tx_er (gmii_tx_er),
        .phy_gmii_txc   (),
        .phy_gmii_rx_clk(clk_125),
        .phy_gmii_rxd   (gmii_txd),
        .phy_gmii_rx_dv (gmii_tx_en),
        .phy_gmii_rx_er (gmii_tx_er),
        .mdc            (),
        .mdio_i         (1'b1),
        .mdio_o         (),
        .mdio_oe        (),
        .cfg_ip_addr    (),
        .irq            ()
    );

    // =========================================================================
    // CSR init: CTRL = tx_en | rx_en | promisc | full_duplex | jumbo_en
    // =========================================================================
    reg init_done;
    reg aw_done, w_done;
    always @(posedge clk or negedge lb_rst_n) begin
        if (!lb_rst_n) begin
            awaddr    <= 8'h04;
            wdata     <= 32'h0000_0067;
            awvalid   <= 1'b0;
            wvalid    <= 1'b0;
            bready    <= 1'b0;
            aw_done   <= 1'b0;
            w_done    <= 1'b0;
            init_done <= 1'b0;
        end else if (!init_done) begin
            awvalid <= !aw_done && !(awvalid && awready);
            wvalid  <= !w_done  && !(wvalid  && wready);
            if (awvalid && awready) aw_done <= 1'b1;
            if (wvalid  && wready)  w_done  <= 1'b1;
            bready <= 1'b1;
            if (bvalid && bready) begin
                bready    <= 1'b0;
                init_done <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Frame length table (payload bytes; frame = 14 + payload, FCS added)
    // =========================================================================
    function [13:0] payload_len;
        input [2:0] sel;
        begin
            case (sel)
                3'd0: payload_len = 14'd46;
                3'd1: payload_len = 14'd60;
                3'd2: payload_len = 14'd1500;
                3'd3: payload_len = 14'd1501;
                3'd4: payload_len = 14'd4000;
                3'd5: payload_len = 14'd4097;
                3'd6: payload_len = 14'd8000;
                default: payload_len = 14'd9000;
            endcase
        end
    endfunction

    // Expected byte at index idx of frame seq (header + seq + pattern).
    function [7:0] frame_byte;
        input [31:0] seq;
        input [13:0] idx;
        begin
            if (idx < 14'd6)        frame_byte = 8'hFF;                   // DA bcast
            else if (idx == 14'd6)  frame_byte = 8'h02;                   // SA
            else if (idx < 14'd11)  frame_byte = 8'h00;
            else if (idx == 14'd11) frame_byte = 8'h02;
            else if (idx == 14'd12) frame_byte = 8'h88;                   // EtherType
            else if (idx == 14'd13) frame_byte = 8'hB5;                   // 0x88B5
            else if (idx == 14'd14) frame_byte = seq[31:24];
            else if (idx == 14'd15) frame_byte = seq[23:16];
            else if (idx == 14'd16) frame_byte = seq[15:8];
            else if (idx == 14'd17) frame_byte = seq[7:0];
            else                    frame_byte = seq[7:0] + idx[7:0];
        end
    endfunction

    // =========================================================================
    // Generator
    // =========================================================================
    reg [31:0] tx_seq;
    reg [13:0] tx_idx, tx_last_idx;
    reg        tx_busy;
    reg [31:0] tx_frames;

    always @(posedge clk or negedge lb_rst_n) begin
        if (!lb_rst_n) begin
            tx_seq      <= 32'd0;
            tx_idx      <= 14'd0;
            tx_last_idx <= 14'd0;
            tx_busy     <= 1'b0;
            tx_tvalid   <= 1'b0;
            tx_tlast    <= 1'b0;
            tx_tdata    <= 8'd0;
            tx_frames   <= 32'd0;
        end else begin
            if (clear) tx_frames <= 32'd0;
            if (!tx_busy) begin
                if (run && init_done) begin
                    tx_busy     <= 1'b1;
                    tx_idx      <= 14'd0;
                    tx_last_idx <= 14'd13 + payload_len(tx_seq[2:0]);
                    tx_tvalid   <= 1'b1;
                    tx_tdata    <= frame_byte(tx_seq, 14'd0);
                    tx_tlast    <= 1'b0;
                end
            end else if (tx_tready) begin
                if (tx_tlast) begin
                    tx_busy   <= 1'b0;
                    tx_tvalid <= 1'b0;
                    tx_tlast  <= 1'b0;
                    tx_seq    <= tx_seq + 1'b1;
                    if (!clear) tx_frames <= tx_frames + 1'b1;
                end else begin
                    tx_idx   <= tx_idx + 1'b1;
                    tx_tdata <= frame_byte(tx_seq, tx_idx + 1'b1);
                    tx_tlast <= (tx_idx + 1'b1 == tx_last_idx);
                end
            end
        end
    end

    // =========================================================================
    // Checker
    // =========================================================================
    // Input register stage: keeps the RX AXIS buffer's block-RAM clock-to-out
    // off the compare/count logic below (one path failed 100 MHz without it).
    reg  [7:0] rx_tdata;
    reg        rx_tvalid, rx_tlast, rx_terror, rx_tsof;
    always @(posedge clk or negedge lb_rst_n) begin
        if (!lb_rst_n) begin
            rx_tdata  <= 8'd0;
            rx_tvalid <= 1'b0;
            rx_tlast  <= 1'b0;
            rx_terror <= 1'b0;
            rx_tsof   <= 1'b0;
        end else begin
            rx_tdata  <= m_rx_tdata;
            rx_tvalid <= m_rx_tvalid;
            rx_tlast  <= m_rx_tlast;
            rx_terror <= m_rx_terror;
            rx_tsof   <= m_rx_tsof;
        end
    end

    reg [13:0] rx_idx;
    reg [31:0] rx_seq;
    reg        rx_mismatch;
    reg [31:0] rx_exp_seq;
    reg        rx_seen_any;
    reg [31:0] rx_ok, rx_ok_big, rx_bad, rx_terr, seq_gap;
    reg [15:0] max_ok_len, first_bad_len, first_bad_seq;
    reg        first_bad_set;

    wire [13:0] cur_idx = rx_tsof ? 14'd0 : rx_idx;
    wire [31:0] cur_seq = (cur_idx == 14'd14) ? {rx_tdata, rx_seq[23:0]} :
                          (cur_idx == 14'd15) ? {rx_seq[31:24], rx_tdata, rx_seq[15:0]} :
                          (cur_idx == 14'd16) ? {rx_seq[31:16], rx_tdata, rx_seq[7:0]} :
                          (cur_idx == 14'd17) ? {rx_seq[31:8], rx_tdata} : rx_seq;
    // Header bytes and the pattern are checked; the seq bytes define the frame.
    wire byte_bad = ((cur_idx < 14'd14) || (cur_idx > 14'd17)) &&
                    (rx_tdata != frame_byte(cur_seq, cur_idx));
    wire mism_now = (rx_tsof ? 1'b0 : rx_mismatch) | byte_bad;
    wire [15:0] fr_len  = {2'b00, cur_idx} + 16'd1;
    wire [15:0] exp_len = 16'd14 + {2'b00, payload_len(cur_seq[2:0])};
    wire fr_good = !mism_now && !rx_terror && (fr_len == exp_len);

    always @(posedge clk or negedge lb_rst_n) begin
        if (!lb_rst_n) begin
            rx_idx        <= 14'd0;
            rx_seq        <= 32'd0;
            rx_mismatch   <= 1'b0;
            rx_exp_seq    <= 32'd0;
            rx_seen_any   <= 1'b0;
            rx_ok         <= 32'd0;
            rx_ok_big     <= 32'd0;
            rx_bad        <= 32'd0;
            rx_terr       <= 32'd0;
            seq_gap       <= 32'd0;
            max_ok_len    <= 16'd0;
            first_bad_len <= 16'd0;
            first_bad_seq <= 16'd0;
            first_bad_set <= 1'b0;
        end else if (clear) begin
            rx_ok         <= 32'd0;
            rx_ok_big     <= 32'd0;
            rx_bad        <= 32'd0;
            rx_terr       <= 32'd0;
            seq_gap       <= 32'd0;
            max_ok_len    <= 16'd0;
            first_bad_len <= 16'd0;
            first_bad_seq <= 16'd0;
            first_bad_set <= 1'b0;
            rx_seen_any   <= 1'b0;
        end else if (rx_tvalid) begin
            rx_seq      <= cur_seq;
            rx_mismatch <= mism_now;
            rx_idx      <= (cur_idx == 14'h3FFF) ? cur_idx : cur_idx + 1'b1;
            if (rx_tlast) begin
                rx_idx <= 14'd0;
                if (fr_good) begin
                    rx_ok <= rx_ok + 1'b1;
                    if (fr_len > 16'd4083) rx_ok_big <= rx_ok_big + 1'b1;
                    if (fr_len > max_ok_len) max_ok_len <= fr_len;
                end else begin
                    rx_bad <= rx_bad + 1'b1;
                    if (!first_bad_set) begin
                        first_bad_set <= 1'b1;
                        first_bad_len <= fr_len;
                        first_bad_seq <= cur_seq[15:0];
                    end
                end
                if (rx_terror) rx_terr <= rx_terr + 1'b1;
                if (rx_seen_any && cur_seq != rx_exp_seq) seq_gap <= seq_gap + 1'b1;
                rx_seen_any <= 1'b1;
                rx_exp_seq  <= cur_seq + 1'b1;
            end
        end
    end

    assign status = {12'hB0A, 1'b0, mmcm_locked, run, init_done,
                     first_bad_seq, first_bad_len, max_ok_len,
                     seq_gap, rx_terr, rx_bad, rx_ok_big, rx_ok, tx_frames};

endmodule
