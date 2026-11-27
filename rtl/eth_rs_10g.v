// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_rs_10g.v - 10G reconciliation sublayer link fault signalling
// (IEEE 802.3 clause 46.3.4) on a 64-bit XGMII: two 32-bit columns per word,
// column 0 in bits [31:0] / [3:0], lane 0 in the low byte of each.
//
// RX (rx_clk, one word per rx_valid): a column is a fault sequence when lane
// 0 is the sequence control character 0x9C, lanes 1..3 are data, lanes 1 and
// 2 are 0x00, and lane 3 is 0x01 (local fault) or 0x02 (remote fault). The
// link fault state machine of IEEE 802.3 figure 46-11: four fault sequences
// of one type in a row, each with fewer than 128 columns without a fault
// sequence before it, report that fault. A sequence of the other type starts
// the count of four again with that type; a fault already reported stays
// reported meanwhile. 128 columns in a row with no fault sequence of either
// type clear the report and the count. A PCS without block lock sends local
// fault sequences, so a lost link reports a local fault here.
//
// TX (tx_clk, one word per tx_ce): with a local fault reported, every word
// the MAC sends that is all idles goes out as two remote fault sequences, to
// tell the far end. With either fault reported, tx_fault asks the MAC side to
// start no new frame (the frame part-way out is finished: idle words follow
// it, and become remote fault sequences with a local fault). The output is
// registered: one word of latency.
//
// rx_fault (rx_clk) is the reported fault, coded 2'b00 none, 2'b01 local,
// 2'b11 remote: bit 0 is "any fault". The TX side takes two single bits
// across, each through its own two-flop synchronizer: bit 0 of rx_fault, and
// a register that is 1 with a local fault. tx_fault is either bit; remote
// fault sequences go out only with both. Whatever order the two bits arrive
// in, a transition shows no fault that was not reported, and no remote fault
// sequences without a local fault. rx_fault is also a 2-bit code for other
// clock domains (eth_mac_sys_10g STATUS): there the code passes through
// 2'b01 or 2'b10 between none and remote, which a reader must filter.
// Verilog 2001
// =============================================================================
module eth_rs_10g (
    // RX (rx_clk)
    input  wire        rx_clk,
    input  wire        rx_rst_n,
    input  wire [63:0] rxd,
    input  wire [7:0]  rxc,
    input  wire        rx_valid,
    output reg  [1:0]  rx_fault,
    // TX (tx_clk)
    input  wire        tx_clk,
    input  wire        tx_rst_n,
    input  wire        tx_ce,
    input  wire [63:0] mac_txd,
    input  wire [7:0]  mac_txc,
    output reg  [63:0] txd,
    output reg  [7:0]  txc,
    output wire        tx_fault
);

    localparam [1:0] F_NONE = 2'b00, F_LOCAL = 2'b01, F_REMOTE = 2'b11;
    localparam [1:0] S_OK = 2'd0, S_COUNT = 2'd1, S_FAULT = 2'd2;

    // =========================================================================
    // RX: link fault state machine, two columns per word
    // =========================================================================
    // column kind: 0 none, F_LOCAL, F_REMOTE
    function [1:0] col_seq;
        input [31:0] d;
        input [3:0]  c;
        begin
            if (c == 4'b0001 && d[7:0] == 8'h9C && d[23:8] == 16'h0000 &&
                d[31:24] == 8'h01)
                col_seq = F_LOCAL;
            else if (c == 4'b0001 && d[7:0] == 8'h9C && d[23:8] == 16'h0000 &&
                     d[31:24] == 8'h02)
                col_seq = F_REMOTE;
            else
                col_seq = F_NONE;
        end
    endfunction

    // state {fault[1:0], st[1:0], typ[1:0], seqs[1:0], cols[7:0]}: 16 bits.
    // typ: the type of the last fault sequence; seqs: how many of that type
    // in a row (S_COUNT); cols: columns without a fault sequence since it.
    function [15:0] step;
        input [15:0] s;
        input [1:0]  k;             // this column's kind
        reg   [1:0]  f, st, typ, seqs;
        reg   [7:0]  cols;
        begin
            f    = s[15:14];
            st   = s[13:12];
            typ  = s[11:10];
            seqs = s[9:8];
            cols = s[7:0];
            if (st == S_OK) begin
                if (k != F_NONE) begin
                    st = S_COUNT; typ = k; seqs = 2'd1; cols = 8'd0;
                end
            end else if (k == F_NONE) begin
                // the 128th column in a row without a fault sequence
                if (cols == 8'd127) begin
                    st = S_OK; f = F_NONE; cols = 8'd0;
                end else
                    cols = cols + 8'd1;
            end else if (k != typ) begin
                // the other type: count it from one; the fault stays
                st = S_COUNT; typ = k; seqs = 2'd1; cols = 8'd0;
            end else begin
                if (st == S_COUNT) begin
                    if (seqs == 2'd3) begin
                        st = S_FAULT; f = typ;
                    end else
                        seqs = seqs + 2'd1;
                end
                cols = 8'd0;
            end
            step = {f, st, typ, seqs, cols};
        end
    endfunction

    reg  [15:0] lf_s;
    wire [15:0] lf_1 = step(lf_s, col_seq(rxd[31:0], rxc[3:0]));
    wire [15:0] lf_2 = step(lf_1, col_seq(rxd[63:32], rxc[7:4]));
    reg         rx_local;           // rx_fault == F_LOCAL, for the TX side

    always @(posedge rx_clk or negedge rx_rst_n) begin
        if (!rx_rst_n) begin
            lf_s     <= 16'd0;
            rx_fault <= F_NONE;
            rx_local <= 1'b0;
        end else if (rx_valid) begin
            lf_s     <= lf_2;
            rx_fault <= lf_2[15:14];
            rx_local <= (lf_2[15:14] == F_LOCAL);
        end
    end

    // =========================================================================
    // TX
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [1:0] any_s;
    (* ASYNC_REG = "TRUE" *) reg [1:0] loc_s;
    always @(posedge tx_clk or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            any_s <= 2'b00;
            loc_s <= 2'b00;
        end else begin
            any_s <= {any_s[0], rx_fault[0]};
            loc_s <= {loc_s[0], rx_local};
        end
    end

    assign tx_fault = any_s[1] || loc_s[1];
    wire   send_rf  = any_s[1] && loc_s[1];

    localparam [63:0] IDLE_D = 64'h0707_0707_0707_0707;
    localparam [63:0] RF_D   = 64'h0200_009C_0200_009C;
    wire idle_word = (mac_txc == 8'hFF) && (mac_txd == IDLE_D);

    always @(posedge tx_clk or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            txd <= IDLE_D;
            txc <= 8'hFF;
        end else if (tx_ce) begin
            if (send_rf && idle_word) begin
                txd <= RF_D;
                txc <= 8'h11;
            end else begin
                txd <= mac_txd;
                txc <= mac_txc;
            end
        end
    end

endmodule
