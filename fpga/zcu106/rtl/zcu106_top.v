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
// The EIO can also switch either laser off, reset the SFP1 core, turn
// auto-negotiation off or restart it, and reads per-hop GMII frame counters
// and a userclk2 frequency meter (see the EIO block).
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
`ifdef ZCU106_SFP1_LB
    // The loopback build can also switch either laser off, and reset the
    // SFP1 core, from the EIO (bits listed with the PCS/PMA AN controls).
    wire [15:0] lb_ctrl;
    (* ASYNC_REG = "TRUE" *) reg [1:0] laser0_off_sync, laser1_off_sync,
                                       sfp1_rst_sync;
    always @(posedge clk_50) begin
        laser0_off_sync <= {laser0_off_sync[0], lb_ctrl[8]};
        laser1_off_sync <= {laser1_off_sync[0], lb_ctrl[4]};
        sfp1_rst_sync   <= {sfp1_rst_sync[0],   lb_ctrl[5]};
    end
    assign SFP0_TX_DISABLE_B = refclk_ready & ~laser0_off_sync[1];
`else
    assign SFP0_TX_DISABLE_B = refclk_ready;
`endif

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

`ifdef ZCU106_SFP1_LB
    // fcapz EIO outputs (TCK domain, static levels set by the host):
    //   [0] run  [1] clear  [2] negative frames  [3] short payloads
    //       (all four go to sfp_lb_tester, which synchronizes them)
    //   [4] SFP1 laser off  [5] SFP1 PCS/PMA reset  [6] AN off (both cores,
    //   ORed with DIP 0)  [7] AN restart (both, rising edge)  [8] SFP0 laser
    //   off (no effect while J16 forces the laser on)
    (* ASYNC_REG = "TRUE" *) reg [1:0] an_off_sync, an_rst_sync, lb_clr_sync;
    always @(posedge userclk2) begin
        an_off_sync <= {an_off_sync[0], lb_ctrl[6]};
        an_rst_sync <= {an_rst_sync[0], lb_ctrl[7]};
        lb_clr_sync <= {lb_clr_sync[0], lb_ctrl[1]};
    end
    wire an_disable = an_dis_sync[1] | an_off_sync[1];
    wire an_restart = an_rst_sync[1];
`else
    wire an_disable = an_dis_sync[1];
    wire an_restart = 1'b0;
`endif

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
        .configuration_vector   ({~an_disable, 4'b0000}),
        .an_interrupt           (),
        // 1000BASE-X base page: full duplex only, no PAUSE advertised
        .an_adv_config_vector   (16'h0020),
        .an_restart_config      (an_restart),
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
        .configuration_vector   ({~an_disable, 4'b0000}),
        .an_interrupt           (),
        .an_adv_config_vector   (16'h0020),
        .an_restart_config      (an_restart),
        .status_vector          (lb_pcs_status),
        .reset                  (pcs_reset | sfp1_rst_sync[1]),
        .signal_detect          (1'b1)
    );

    assign SFP1_TX_DISABLE_B = refclk_ready & ~laser1_off_sync[1];

    // Link-down events per core (falling edges of status_vector[0])
    reg        link0_q, link1_q;
    reg [15:0] link0_downs, link1_downs;
    always @(posedge userclk2 or negedge rst_n) begin
        if (!rst_n) begin
            link0_q     <= 1'b0;
            link1_q     <= 1'b0;
            link0_downs <= 16'd0;
            link1_downs <= 16'd0;
        end else begin
            link0_q <= pcs_status[0];
            link1_q <= lb_pcs_status[0];
            if (lb_clr_sync[1]) begin
                link0_downs <= 16'd0;
                link1_downs <= 16'd0;
            end else begin
                if (link0_q && !pcs_status[0])    link0_downs <= link0_downs + 16'd1;
                if (link1_q && !lb_pcs_status[0]) link1_downs <= link1_downs + 16'd1;
            end
        end
    end

    // Frame counters at each GMII hop (starts of tx_en / rx_dv, and frames
    // with rx_er), to show where frames get lost: tester TX -> SFP1 PCS ->
    // fiber -> SFP0 PCS -> demo RX, and back.
    reg        d_rx_q, d_tx_q, t_rx_q, t_tx_q, d_er_q, t_er_q;
    reg [15:0] demo_rx_frames, demo_tx_frames, tst_rx_frames, tst_tx_frames;
    reg [15:0] demo_rx_errs, tst_rx_errs;
    always @(posedge userclk2 or negedge rst_n) begin
        if (!rst_n) begin
            {d_rx_q, d_tx_q, t_rx_q, t_tx_q, d_er_q, t_er_q} <= 6'd0;
            demo_rx_frames <= 16'd0;
            demo_tx_frames <= 16'd0;
            tst_rx_frames  <= 16'd0;
            tst_tx_frames  <= 16'd0;
            demo_rx_errs   <= 16'd0;
            tst_rx_errs    <= 16'd0;
        end else begin
            d_rx_q <= gmii_rx_dv;
            d_tx_q <= gmii_tx_en;
            t_rx_q <= lb_gmii_rx_dv;
            t_tx_q <= lb_gmii_tx_en;
            d_er_q <= gmii_rx_er;
            t_er_q <= lb_gmii_rx_er;
            if (lb_clr_sync[1]) begin
                demo_rx_frames <= 16'd0;
                demo_tx_frames <= 16'd0;
                tst_rx_frames  <= 16'd0;
                tst_tx_frames  <= 16'd0;
                demo_rx_errs   <= 16'd0;
                tst_rx_errs    <= 16'd0;
            end else begin
                if (gmii_rx_dv    && !d_rx_q) demo_rx_frames <= demo_rx_frames + 16'd1;
                if (gmii_tx_en    && !d_tx_q) demo_tx_frames <= demo_tx_frames + 16'd1;
                if (lb_gmii_rx_dv && !t_rx_q) tst_rx_frames  <= tst_rx_frames  + 16'd1;
                if (lb_gmii_tx_en && !t_tx_q) tst_tx_frames  <= tst_tx_frames  + 16'd1;
                if (gmii_rx_er    && !d_er_q) demo_rx_errs   <= demo_rx_errs   + 16'd1;
                if (lb_gmii_rx_er && !t_er_q) tst_rx_errs    <= tst_rx_errs    + 16'd1;
            end
        end
    end

    // userclk2 frequency: cycles per 2^22 clk_50 cycles (83.9 ms); 125 MHz
    // reads as about 10,485,760. The window is a clk_50 toggle synchronized
    // into userclk2; the result holds for a whole window.
    reg [21:0] fm_div = 22'd0;
    reg        fm_tog = 1'b0;
    always @(posedge clk_50) begin
        fm_div <= fm_div + 22'd1;
        if (fm_div == 22'h3FFFFF) fm_tog <= ~fm_tog;
    end
    (* ASYNC_REG = "TRUE" *) reg [2:0] fm_sync = 3'd0;
    reg [23:0] fm_cnt = 24'd0, fm_meas = 24'd0;
    always @(posedge userclk2) begin
        fm_sync <= {fm_sync[1:0], fm_tog};
        if (fm_sync[2] != fm_sync[1]) begin
            fm_meas <= fm_cnt;
            fm_cnt  <= 24'd1;
        end else if (fm_cnt != 24'hFFFFFF) begin
            fm_cnt  <= fm_cnt + 24'd1;
        end
    end

    wire [383:0] lb_status;
    wire         lb_ok_pulse, lb_bad_pulse;

    sfp_lb_tester u_lb (
        .clk        (userclk2),
        .rst_n      (rst_n),
        .ctrl       (lb_ctrl[3:0]),
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

    // EIO (USER3). eio-write: lb_ctrl, see the AN controls above.
    // eio-read: [383:0] tester status (see sfp_lb_tester.v),
    //   [399:384] SFP0 PCS status_vector, [415:400] SFP1 PCS status_vector,
    //   [431:416] SFP0 link-down count, [447:432] SFP1 link-down count,
    //   [463:448] demo RX frames, [479:464] demo TX frames,
    //   [495:480] tester TX frames, [511:496] tester RX frames,
    //   [527:512] demo RX error frames, [543:528] tester RX error frames,
    //   [567:544] userclk2 cycles per 2^22 clk_50 cycles,
    //   [576] SFP0 GT reset done, [577] SFP1 GT reset done,
    //   [578] refclk ready, [579] AN disabled, [580] REFCLK_SI5328,
    //   [581] MAC out of reset, [595:592] layout version 2,
    //   [607:596] marker 12'h106.
    wire refclk_sel = (REFCLK_SI5328 != 0);
    fcapz_eio_xilinxus #(
        .IN_W  (608),
        .OUT_W (16),
        .CHAIN (3)
    ) u_eio (
        .probe_in  ({12'h106, 4'd2, 10'd0, rst_n, refclk_sel, an_disable,
                     refclk_ready, lb_gt_resetdone, gt_resetdone,
                     8'd0, fm_meas, tst_rx_errs, demo_rx_errs,
                     tst_rx_frames, tst_tx_frames, demo_tx_frames, demo_rx_frames,
                     link1_downs, link0_downs,
                     lb_pcs_status, pcs_status, lb_status}),
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
