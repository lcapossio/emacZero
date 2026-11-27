// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// gt10g_reset.v - Reset sequencer for one GTHE4 channel on QPLL0
// (gthe4_common_10g + gthe4_channel_10g), in place of the Transceiver Wizard
// reset helper. Runs on the free-running DRP clock.
//
//   1. hold everything in reset until GTPOWERGOOD
//   2. pulse QPLL0RESET (HOLD_CYCLES), wait for QPLL0LOCK
//   3. TX and RX in parallel: release GTxXRESET and xXPROGDIVRESET, wait until
//      the user clock buffer is running (x_usrclk_active, the BUFG_GT is held
//      in reset by the top until xXPMARESETDONE), raise xXUSERRDY, wait for
//      xXRESETDONE -> tx_done / rx_done
//
// RXCDRLOCK is not used (UG576 reserves it), so rx_done does not mean the
// receiver is locked to a signal; the PCS block lock says that.
// Each step waits at most TIMEOUT_CYCLES and then starts that path again
// (the whole sequence for the PLL). Losing QPLL0LOCK restarts everything.
// tx_restart / rx_restart (pulses or levels) restart one path, e.g. rx after
// a LOOPBACK change. All status inputs are asynchronous; they are
// synchronized here.
// Verilog 2001
// =============================================================================

module gt10g_reset #(
    parameter HOLD_CYCLES    = 50,        // reset pulse width (1 us at 50 MHz)
    parameter TIMEOUT_CYCLES = 1000000    // per-step timeout (20 ms at 50 MHz)
) (
    input  wire clk,                 // free-running (DRP clock)
    input  wire rst,                 // synchronous to clk, active high
    input  wire tx_restart,
    input  wire rx_restart,

    // Status from the GT (asynchronous)
    input  wire gtpowergood,
    input  wire qpll0lock,
    input  wire tx_usrclk_active,
    input  wire rx_usrclk_active,
    input  wire txresetdone,
    input  wire rxresetdone,

    // Resets and ready to the GT
    output reg  qpll0reset,
    output reg  gttxreset,
    output reg  gtrxreset,
    output reg  txprogdivreset,
    output reg  rxprogdivreset,
    output reg  txuserrdy,
    output reg  rxuserrdy,

    output reg  tx_done,
    output reg  rx_done
);

    // ---- synchronizers ----
    (* ASYNC_REG = "TRUE" *) reg [1:0] s_pg, s_lock, s_txa, s_rxa, s_txd, s_rxd;
    always @(posedge clk) begin
        s_pg   <= {s_pg[0],   gtpowergood};
        s_lock <= {s_lock[0], qpll0lock};
        s_txa  <= {s_txa[0],  tx_usrclk_active};
        s_rxa  <= {s_rxa[0],  rx_usrclk_active};
        s_txd  <= {s_txd[0],  txresetdone};
        s_rxd  <= {s_rxd[0],  rxresetdone};
    end
    wire pg = s_pg[1], lock = s_lock[1];
    wire txa = s_txa[1], rxa = s_rxa[1], txd = s_txd[1], rxd = s_rxd[1];

    localparam CW = 24;

    // ---- PLL sequence ----
    localparam P_PWR  = 2'd0,   // wait for GTPOWERGOOD
               P_RST  = 2'd1,   // QPLL0RESET pulse
               P_LOCK = 2'd2,   // wait for lock
               P_RUN  = 2'd3;   // locked
    reg [1:0]    pst;
    reg [CW-1:0] pcnt;
    wire pll_ok = (pst == P_RUN);

    always @(posedge clk) begin
        if (rst) begin
            pst        <= P_PWR;
            pcnt       <= {CW{1'b0}};
            qpll0reset <= 1'b1;
        end else begin
            pcnt <= pcnt + 1'b1;
            case (pst)
                P_PWR: begin
                    qpll0reset <= 1'b1;
                    pcnt       <= {CW{1'b0}};
                    if (pg) pst <= P_RST;
                end
                P_RST: begin
                    qpll0reset <= 1'b1;
                    if (pcnt == HOLD_CYCLES - 1) begin
                        qpll0reset <= 1'b0;
                        pcnt       <= {CW{1'b0}};
                        pst        <= P_LOCK;
                    end
                end
                P_LOCK: begin
                    if (lock) begin
                        pst <= P_RUN;
                    end else if (pcnt == TIMEOUT_CYCLES - 1) begin
                        pcnt <= {CW{1'b0}};
                        pst  <= P_RST;
                    end
                end
                default: begin   // P_RUN
                    pcnt <= {CW{1'b0}};
                    if (!lock || !pg) pst <= P_PWR;
                end
            endcase
        end
    end

    // ---- TX / RX path sequences (same shape) ----
    localparam X_RST  = 2'd0,   // GTxXRESET + PROGDIVRESET held
               X_CLK  = 2'd1,   // released, wait for the user clock
               X_DONE = 2'd2,   // USERRDY up, wait for reset done
               X_RUN  = 2'd3;

    reg [1:0]    tst, rst_x;
    reg [CW-1:0] tcnt, rcnt;

    always @(posedge clk) begin
        if (rst || !pll_ok || tx_restart) begin
            tst            <= X_RST;
            tcnt           <= {CW{1'b0}};
            gttxreset      <= 1'b1;
            txprogdivreset <= 1'b1;
            txuserrdy      <= 1'b0;
            tx_done        <= 1'b0;
        end else begin
            tcnt <= tcnt + 1'b1;
            case (tst)
                X_RST: if (tcnt == HOLD_CYCLES - 1) begin
                    gttxreset      <= 1'b0;
                    txprogdivreset <= 1'b0;
                    tcnt           <= {CW{1'b0}};
                    tst            <= X_CLK;
                end
                X_CLK: if (txa) begin
                    txuserrdy <= 1'b1;
                    tcnt      <= {CW{1'b0}};
                    tst       <= X_DONE;
                end else if (tcnt == TIMEOUT_CYCLES - 1) begin
                    gttxreset      <= 1'b1;
                    txprogdivreset <= 1'b1;
                    tcnt           <= {CW{1'b0}};
                    tst            <= X_RST;
                end
                X_DONE: if (txd) begin
                    tx_done <= 1'b1;
                    tst     <= X_RUN;
                end else if (tcnt == TIMEOUT_CYCLES - 1) begin
                    gttxreset      <= 1'b1;
                    txprogdivreset <= 1'b1;
                    txuserrdy      <= 1'b0;
                    tcnt           <= {CW{1'b0}};
                    tst            <= X_RST;
                end
                default: begin   // X_RUN
                    tcnt <= {CW{1'b0}};
                    if (!txd || !txa) begin
                        gttxreset      <= 1'b1;
                        txprogdivreset <= 1'b1;
                        txuserrdy      <= 1'b0;
                        tx_done        <= 1'b0;
                        tst            <= X_RST;
                    end
                end
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst || !pll_ok || rx_restart) begin
            rst_x          <= X_RST;
            rcnt           <= {CW{1'b0}};
            gtrxreset      <= 1'b1;
            rxprogdivreset <= 1'b1;
            rxuserrdy      <= 1'b0;
            rx_done        <= 1'b0;
        end else begin
            rcnt <= rcnt + 1'b1;
            case (rst_x)
                X_RST: if (rcnt == HOLD_CYCLES - 1) begin
                    gtrxreset      <= 1'b0;
                    rxprogdivreset <= 1'b0;
                    rcnt           <= {CW{1'b0}};
                    rst_x          <= X_CLK;
                end
                X_CLK: if (rxa) begin
                    rxuserrdy <= 1'b1;
                    rcnt      <= {CW{1'b0}};
                    rst_x     <= X_DONE;
                end else if (rcnt == TIMEOUT_CYCLES - 1) begin
                    gtrxreset      <= 1'b1;
                    rxprogdivreset <= 1'b1;
                    rcnt           <= {CW{1'b0}};
                    rst_x          <= X_RST;
                end
                X_DONE: if (rxd) begin
                    rx_done <= 1'b1;
                    rst_x   <= X_RUN;
                end else if (rcnt == TIMEOUT_CYCLES - 1) begin
                    gtrxreset      <= 1'b1;
                    rxprogdivreset <= 1'b1;
                    rxuserrdy      <= 1'b0;
                    rcnt           <= {CW{1'b0}};
                    rst_x          <= X_RST;
                end
                default: begin   // X_RUN
                    rcnt <= {CW{1'b0}};
                    if (!rxd || !rxa) begin
                        gtrxreset      <= 1'b1;
                        rxprogdivreset <= 1'b1;
                        rxuserrdy      <= 1'b0;
                        rx_done        <= 1'b0;
                        rst_x          <= X_RST;
                    end
                end
            endcase
        end
    end

endmodule
