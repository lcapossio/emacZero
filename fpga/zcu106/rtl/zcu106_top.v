// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// zcu106_top.v - emacZero over SFP (1000BASE-X) on the AMD ZCU106
//
//   SFP cage 0 <-> GTH <-> 1G/2.5G PCS/PMA IP (1000BASE-X) <-GMII-> eth_mac_sys
//
// eth_mac_sys runs in PHY_INTERFACE="GMII" mode with its system clock, its
// GMII TX clock and its GMII RX clock all on the PCS/PMA 125 MHz userclk2, so
// the whole MAC and the demo L3 stack (ARP, ICMP echo, UDP echo on port 9999)
// are one 125 MHz clock domain.
//
// GTH reference clock (REFCLK_SI5328, set by build_zcu106.tcl):
//   0 (default): USER_MGT_SI570 (U56), 156.25 MHz at power-up, Quad 226
//      MGTREFCLK1 (U10/U9), shared into Quad 225. No setup needed; this is
//      the clock the AMD and verilog-ethernet ZCU102/ZCU106 SFP designs use.
//   1: Si5328 (U20), Quad 225 MGTREFCLK1 (W10/W9). It has no non-volatile
//      memory, so i2c_init programs it to 125 MHz over PL IIC1 (through the
//      TCA9548A mux) before the PCS/PMA reset is released.
// Either way the GT makes the 125 MHz userclk2. A watchdog re-pulses the
// PCS/PMA reset every 2 s until the GT reports reset done (covers the Si5328
// lock time, which can be ~20 s). This logic runs from the free-running
// 300 MHz user clock divided to 50 MHz, which is also the PCS/PMA independent
// (DRP / reset) clock.
//
// LEDs: 0 refclk ready (Si5328 programmed, or always on with the Si570)
//       1 I2C NACK seen        2 GT reset done
//       3 PCS link sync        4 1000BASE-X link up 5 RX frame activity
//       6 TX frame activity    7 userclk2 heartbeat (GT clock running)
// DIP 0: 1 disables 1000BASE-X auto-negotiation (for partners without AN).
//
// With ZCU106_SFP1_LB defined (build_zcu106.tcl ... lb), SFP cage 1 gets a
// second PCS/PMA and sfp_lb_tester, which exercises the demo on SFP0 over a
// fiber between the two cages; the LEDs then show the loopback test (see
// the LED block at the end) and an fcapz EIO drives and reads the tester.
// Verilog 2001
// =============================================================================

module zcu106_top #(
    parameter REFCLK_SI5328 = 0         // 0: USER_MGT_SI570, 1: Si5328
) (
    // 300 MHz free-running user clock (Si570)
    input  wire       USER_SI570_SYSCLK_P,
    input  wire       USER_SI570_SYSCLK_N,
    input  wire       CPU_RESET,          // active high

    // SFP cage 0, GTH, and its reference clock (see REFCLK_SI5328)
    input  wire       SFP_REFCLK_P,
    input  wire       SFP_REFCLK_N,
    output wire       SFP0_TX_P,
    output wire       SFP0_TX_N,
    input  wire       SFP0_RX_P,
    input  wire       SFP0_RX_N,
    output wire       SFP0_TX_DISABLE_B,  // high = laser on (J16 also forces on)
`ifdef ZCU106_SFP1_LB
    // SFP cage 1 (loopback tester), same GTH quad
    output wire       SFP1_TX_P,
    output wire       SFP1_TX_N,
    input  wire       SFP1_RX_P,
    input  wire       SFP1_RX_N,
    output wire       SFP1_TX_DISABLE_B,
`endif

    // PL I2C to the Si5328 (through the TCA9548A mux); released (high-Z)
    // when REFCLK_SI5328 = 0
    output wire       IIC_SCL,            // open drain (no clock stretching)
    inout  wire       IIC_SDA,

    input  wire       DIP_AN_DISABLE,
    output wire [7:0] LED
);

    localparam [47:0] OUR_MAC = 48'h02_00_00_00_00_01;
    localparam [15:0] UDP_ECHO_PORT = 16'd9999;

    // =========================================================================
    // 50 MHz free-running clock: 300 MHz / 6
    // =========================================================================
    wire clk_300_ibuf;
    wire clk_50;

    IBUFDS u_sysclk_ibuf (
        .I  (USER_SI570_SYSCLK_P),
        .IB (USER_SI570_SYSCLK_N),
        .O  (clk_300_ibuf)
    );

    BUFGCE_DIV #(.BUFGCE_DIVIDE(6)) u_clk_50_buf (
        .I   (clk_300_ibuf),
        .CE  (1'b1),
        .CLR (1'b0),
        .O   (clk_50)
    );

    // CPU_RESET synchronized into clk_50 (async assert, sync release)
    (* ASYNC_REG = "TRUE" *) reg [2:0] rst50_sync;
    always @(posedge clk_50 or posedge CPU_RESET) begin
        if (CPU_RESET) rst50_sync <= 3'b000;
        else           rst50_sync <= {rst50_sync[1:0], 1'b1};
    end
    wire rst50_n = rst50_sync[2];

    // =========================================================================
    // Reference clock bring-up (Si5328 over I2C, or nothing for the Si570)
    // =========================================================================
    wire       scl_t, sda_t;
    wire       refclk_ready;
    wire [7:0] i2c_nacks;

    assign IIC_SCL = scl_t ? 1'bz : 1'b0;
    assign IIC_SDA = sda_t ? 1'bz : 1'b0;

    generate if (REFCLK_SI5328) begin : gen_si5328
    i2c_init #(
        .CLK_HZ      (50_000_000),
        .I2C_HZ      (100_000),
        .START_DELAY (50_000_000),        // 1 s: let the system controller
                                          // finish its own Si5328 setup
        .RETRY_DELAY (50_000_000 / 10),
        .DONE_DELAY  (50_000_000 / 10)    // lock wait is the GT watchdog's job
    ) u_si5328_init (
        .clk        (clk_50),
        .rst_n      (rst50_n),
        .scl_t      (scl_t),
        .sda_t      (sda_t),
        .sda_i      (IIC_SDA),
        .done       (refclk_ready),
        .busy       (),
        .nack_count (i2c_nacks)
    );
    end else begin : gen_si570
    // The USER_MGT_SI570 runs at 156.25 MHz from power-up; leave I2C alone.
    assign scl_t       = 1'b1;
    assign sda_t       = 1'b1;
    assign refclk_ready = 1'b1;
    assign i2c_nacks   = 8'd0;
    end endgenerate

    // Keep the SFP laser off until the reference clock is ready.
    assign SFP0_TX_DISABLE_B = refclk_ready;

    // GT bring-up watchdog: hold the PCS/PMA in reset until the reference
    // clock is ready, then pulse its reset for 1 ms every 2 s until the GT
    // reports reset done (covers the Si5328 lock time).
    localparam integer WD_PERIOD   = 100_000_000;  // 2 s at 50 MHz
    localparam integer RESET_PULSE = 50_000;       // 1 ms
    wire       gt_resetdone;
    (* ASYNC_REG = "TRUE" *) reg [2:0] gt_done_sync;
    reg [26:0] wd_cnt;
    reg        pcs_reset;
    always @(posedge clk_50) gt_done_sync <= {gt_done_sync[1:0], gt_resetdone};
    always @(posedge clk_50 or negedge rst50_n) begin
        if (!rst50_n) begin
            wd_cnt    <= 27'd0;
            pcs_reset <= 1'b1;
        end else if (!refclk_ready) begin
            wd_cnt    <= 27'd0;
            pcs_reset <= 1'b1;
        end else if (gt_done_sync[2]) begin
            wd_cnt    <= 27'd0;
            pcs_reset <= 1'b0;
        end else begin
            wd_cnt    <= (wd_cnt == WD_PERIOD - 1) ? 27'd0 : wd_cnt + 27'd1;
            pcs_reset <= (wd_cnt < RESET_PULSE);
        end
    end

    // =========================================================================
    // PCS/PMA (1000BASE-X over GTH, shared logic in core)
    // =========================================================================
    wire        userclk2;
    wire        gtrefclk, userclk, rxuserclk, rxuserclk2;   // shared with SFP1
    wire        gt_mmcm_locked;
    wire        pma_reset_out;
    wire [15:0] pcs_status;

    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire        gmii_tx_er;
    wire [7:0]  gmii_rxd;
    wire        gmii_rx_dv;
    wire        gmii_rx_er;

    // DIP_AN_DISABLE is a static strap; synchronize it into userclk2, the
    // clock the PCS/PMA samples configuration_vector on.
    (* ASYNC_REG = "TRUE" *) reg [1:0] an_dis_sync;
    always @(posedge userclk2) an_dis_sync <= {an_dis_sync[0], DIP_AN_DISABLE};

    pcs_pma_1000basex u_pcs_pma (
        .gtrefclk_p             (SFP_REFCLK_P),
        .gtrefclk_n             (SFP_REFCLK_N),
        .gtrefclk_out           (gtrefclk),
        .txn                    (SFP0_TX_N),
        .txp                    (SFP0_TX_P),
        .rxn                    (SFP0_RX_N),
        .rxp                    (SFP0_RX_P),
        .independent_clock_bufg (clk_50),
        .userclk_out            (userclk),
        .userclk2_out           (userclk2),
        .rxuserclk_out          (rxuserclk),
        .rxuserclk2_out         (rxuserclk2),
        .gtpowergood            (),
        .resetdone              (gt_resetdone),
        .pma_reset_out          (pma_reset_out),
        .mmcm_locked_out        (gt_mmcm_locked),
        .gmii_txd               (gmii_txd),
        .gmii_tx_en             (gmii_tx_en),
        .gmii_tx_er             (gmii_tx_er),
        .gmii_rxd               (gmii_rxd),
        .gmii_rx_dv             (gmii_rx_dv),
        .gmii_rx_er             (gmii_rx_er),
        .gmii_isolate           (),
        // [4] AN enable, [3] isolate, [2] powerdown, [1] loopback, [0] unidir
        .configuration_vector   ({~an_dis_sync[1], 4'b0000}),
        .an_interrupt           (),
        // 1000BASE-X base page: full duplex only, no PAUSE advertised
        .an_adv_config_vector   (16'h0020),
        .an_restart_config      (1'b0),
        .status_vector          (pcs_status),
        .reset                  (pcs_reset),
        .signal_detect          (1'b1)
    );

    // MAC reset: released once the GT is up and userclk2 is running. The
    // three PCS/PMA status bits are each synchronized into clk_50 (reset done
    // reuses the watchdog's gt_done_sync) and then combined in a flop, so the
    // async reset below is driven glitch-free.
    (* ASYNC_REG = "TRUE" *) reg [1:0] gt_locked_sync, pma_rst_sync;
    reg mac_rst_async_n;
    always @(posedge clk_50 or negedge rst50_n) begin
        if (!rst50_n) begin
            gt_locked_sync  <= 2'b00;
            pma_rst_sync    <= 2'b11;
            mac_rst_async_n <= 1'b0;
        end else begin
            gt_locked_sync  <= {gt_locked_sync[0],  gt_mmcm_locked};
            pma_rst_sync    <= {pma_rst_sync[0],    pma_reset_out};
            mac_rst_async_n <= gt_done_sync[2] & gt_locked_sync[1] & ~pma_rst_sync[1];
        end
    end
    (* ASYNC_REG = "TRUE" *) reg [2:0] mac_rst_sync;
    always @(posedge userclk2 or negedge mac_rst_async_n) begin
        if (!mac_rst_async_n) mac_rst_sync <= 3'b000;
        else                  mac_rst_sync <= {mac_rst_sync[1:0], 1'b1};
    end
    wire rst_n = mac_rst_sync[2];

    // =========================================================================
    // emacZero MAC + demo L3 stack on SFP0
    // =========================================================================
    wire demo_rx_frame, demo_tx_frame;

    zcu106_eth_demo #(
        .OUR_MAC       (OUR_MAC),
        .UDP_ECHO_PORT (UDP_ECHO_PORT)
    ) u_demo (
        .clk        (userclk2),
        .rst_n      (rst_n),
        .gmii_txd   (gmii_txd),
        .gmii_tx_en (gmii_tx_en),
        .gmii_tx_er (gmii_tx_er),
        .gmii_rxd   (gmii_rxd),
        .gmii_rx_dv (gmii_rx_dv),
        .gmii_rx_er (gmii_rx_er),
        .rx_frame   (demo_rx_frame),
        .tx_frame   (demo_tx_frame)
    );

`ifdef ZCU106_SFP1_LB
    // =========================================================================
    // SFP1 loopback tester: a second PCS/PMA on the neighboring GTH channel
    // (sharing core 0's reference clock, user clocks and resets), with
    // sfp_lb_tester playing a host that pings / ARPs / UDP-echoes the demo
    // on SFP0 over the fiber. Driven and read over JTAG by the fcapz EIO.
    // =========================================================================
    wire [7:0]  lb_gmii_txd, lb_gmii_rxd;
    wire        lb_gmii_tx_en, lb_gmii_tx_er, lb_gmii_rx_dv, lb_gmii_rx_er;
    wire [15:0] lb_pcs_status;
    wire        lb_gt_resetdone;

    pcs_pma_1000basex_ns u_pcs_pma_sfp1 (
        .gtrefclk               (gtrefclk),
        .txn                    (SFP1_TX_N),
        .txp                    (SFP1_TX_P),
        .rxn                    (SFP1_RX_N),
        .rxp                    (SFP1_RX_P),
        .independent_clock_bufg (clk_50),
        .txoutclk               (),
        .gtpowergood            (),
        .rxoutclk               (),
        .resetdone              (lb_gt_resetdone),
        .cplllock               (),
        .mmcm_reset             (),
        .userclk                (userclk),
        .userclk2               (userclk2),
        .pma_reset              (pma_reset_out),
        .mmcm_locked            (gt_mmcm_locked),
        .rxuserclk              (rxuserclk),
        .rxuserclk2             (rxuserclk2),
        .gmii_txd               (lb_gmii_txd),
        .gmii_tx_en             (lb_gmii_tx_en),
        .gmii_tx_er             (lb_gmii_tx_er),
        .gmii_rxd               (lb_gmii_rxd),
        .gmii_rx_dv             (lb_gmii_rx_dv),
        .gmii_rx_er             (lb_gmii_rx_er),
        .gmii_isolate           (),
        .configuration_vector   ({~an_dis_sync[1], 4'b0000}),
        .an_interrupt           (),
        .an_adv_config_vector   (16'h0020),
        .an_restart_config      (1'b0),
        .status_vector          (lb_pcs_status),
        .reset                  (pcs_reset),
        .signal_detect          (1'b1)
    );

    assign SFP1_TX_DISABLE_B = refclk_ready;

    wire [1:0]   lb_ctrl;
    wire [263:0] lb_status;
    wire         lb_ok_pulse, lb_bad_pulse;

    sfp_lb_tester u_lb (
        .clk        (userclk2),
        .rst_n      (rst_n),
        .ctrl       (lb_ctrl),
        .link_ok    (pcs_status[0] && lb_pcs_status[0]),
        .gmii_txd   (lb_gmii_txd),
        .gmii_tx_en (lb_gmii_tx_en),
        .gmii_tx_er (lb_gmii_tx_er),
        .gmii_rxd   (lb_gmii_rxd),
        .gmii_rx_dv (lb_gmii_rx_dv),
        .gmii_rx_er (lb_gmii_rx_er),
        .status     (lb_status),
        .ok_pulse   (lb_ok_pulse),
        .bad_pulse  (lb_bad_pulse)
    );

    // EIO (USER3). eio-write: [0] run, [1] clear.
    // eio-read: [263:0] tester status (see sfp_lb_tester.v),
    //   [279:264] SFP0 PCS status_vector, [295:280] SFP1 PCS status_vector,
    //   [296] SFP0 GT reset done, [297] SFP1 GT reset done,
    //   [298] refclk ready, [319:308] marker 12'h106.
    fcapz_eio_xilinxus #(
        .IN_W  (320),
        .OUT_W (2),
        .CHAIN (3)
    ) u_eio (
        .probe_in  ({12'h106, 9'd0, refclk_ready, lb_gt_resetdone,
                     gt_resetdone, lb_pcs_status, pcs_status, lb_status}),
        .probe_out (lb_ctrl)
    );
`endif

    // =========================================================================
    // LEDs
    // =========================================================================
    // Activity: stretch a one-cycle pulse to ~67 ms at 125 MHz.
`ifdef ZCU106_SFP1_LB
    wire rx_ev = lb_ok_pulse;
    wire tx_ev = lb_bad_pulse;
`else
    wire rx_ev = demo_rx_frame;
    wire tx_ev = demo_tx_frame;
`endif
    reg [22:0] rx_led_cnt, tx_led_cnt;
    reg [26:0] heartbeat = 27'd0;
    always @(posedge userclk2 or negedge rst_n) begin
        if (!rst_n) begin
            rx_led_cnt <= 23'd0;
            tx_led_cnt <= 23'd0;
        end else begin
            if (rx_ev)                  rx_led_cnt <= {23{1'b1}};
            else if (rx_led_cnt != 0)   rx_led_cnt <= rx_led_cnt - 23'd1;
            if (tx_ev)                  tx_led_cnt <= {23{1'b1}};
            else if (tx_led_cnt != 0)   tx_led_cnt <= tx_led_cnt - 23'd1;
        end
    end
    always @(posedge userclk2) heartbeat <= heartbeat + 27'd1;

`ifdef ZCU106_SFP1_LB
    // Loopback build: 0 SFP0 link up  1 SFP1 link up  2 both GTs reset done
    //   3 correct reply seen  4 bad reply / timeout seen  5 tester running
    //   6 any failure counted since clear (sticky)  7 heartbeat
    assign LED[0] = pcs_status[0];
    assign LED[1] = lb_pcs_status[0];
    assign LED[2] = gt_resetdone && lb_gt_resetdone;
    assign LED[3] = (rx_led_cnt != 0);
    assign LED[4] = (tx_led_cnt != 0);
    assign LED[5] = lb_status[263];
    assign LED[6] = (lb_status[191:128] != 64'd0);
    assign LED[7] = heartbeat[26];
`else
    assign LED[0] = refclk_ready;
    assign LED[1] = (i2c_nacks != 8'd0);
    assign LED[2] = gt_resetdone;
    assign LED[3] = pcs_status[1];
    assign LED[4] = pcs_status[0];
    assign LED[5] = (rx_led_cnt != 0);
    assign LED[6] = (tx_led_cnt != 0);
    assign LED[7] = heartbeat[26];
`endif

endmodule
