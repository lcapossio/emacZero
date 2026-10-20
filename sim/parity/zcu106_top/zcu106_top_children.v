// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// zcu106_top_children.v - Parity-only stand-ins for every child of zcu106_top
// (Verilog side; zcu106_top_children.vhd is the line-for-line VHDL twin, read
// by the candidate side). They replace the vendor primitives (IBUFDS,
// BUFGCE_DIV), the Vivado PCS/PMA IP cores, the fcapz debug cores, and the
// RTL children i2c_init, zcu106_eth_demo and sfp_lb_tester, so the
// zcu106_top proof covers the top's own logic and wiring, not the children.
// i2c_init is proven on its own (sim/parity/i2c_init).
//
// Why not port-only stubs: an empty module leaves its outputs undriven (Yosys)
// or 'Z' (GHDL), which the solver folds to constants on both sides, so every
// register behind a child output never changes and the proof is vacuous (a
// mutated VHDL top still "passes"). These stand-ins instead keep a register
// `st` on their own clock (no reset, no initial value) whose next value is
// `st` rotated by one XOR every data input at its own bit position XOR a
// fingerprint of the generics:
//   - every output is a slice of `st`, so it changes over time and reaches
//     any value from the top-level pins that feed the stand-in;
//   - every input reaches the outputs at a distinct bit, so a missing,
//     swapped or wrong connection on the VHDL side diverges;
//   - a generic passed with a different value diverges;
//   - the state sits under the instance name on both sides
//     (u_demo.st, gen_si5328.u_si5328_init.st, ...), so it pairs by name.
// The fingerprint gives every generic its own full-width field (strings one
// bit per legal value), so distinct values never cancel. Clock outputs of the
// PCS/PMA cores are distinct combinational functions of the GT reference
// clock pins; BUFGCE_DIV's output is a register bit clocked by its input, so
// the divided clock is a different clock from the one it divides and logic
// moved between the two domains diverges. The fcapz EIO has no clock port:
// its stand-in is combinational, see its comment.
// =============================================================================

// ---- unisim -----------------------------------------------------------------
module IBUFDS (
    output wire O,
    input  wire I,
    input  wire IB
);
    assign O = I & ~IB;
endmodule

// A register on I that mixes CE, CLR and BUFGCE_DIVIDE (all 32 bits); O is
// one of its bits. So O is a different clock from I, and a wrong divide value
// or a miswired CE / CLR diverges.
module BUFGCE_DIV #(
    parameter BUFGCE_DIVIDE = 1
) (
    output wire O,
    input  wire CE,
    input  wire CLR,
    input  wire I
);
    localparam [31:0] FP = BUFGCE_DIVIDE;
    reg [31:0] st;
    always @(posedge I) st <= {st[30:0], st[31]} ^ FP ^ {30'd0, CLR, CE};
    assign O = st[0];
endmodule

// ---- fpga/zcu106/rtl/i2c_init.v -----------------------------------------------
module i2c_init #(
    parameter CLK_HZ      = 50_000_000,
    parameter I2C_HZ      = 100_000,
    parameter START_DELAY = 50_000_000 / 10,
    parameter RETRY_DELAY = 50_000_000 / 10,
    parameter DONE_DELAY  = 50_000_000 / 2
) (
    input  wire       clk,
    input  wire       rst_n,
    output wire       scl_t,
    output wire       sda_t,
    input  wire       sda_i,
    output wire       done,
    output wire       busy,
    output wire [7:0] nack_count
);
    localparam [31:0] G0 = CLK_HZ;
    localparam [31:0] G1 = I2C_HZ;
    localparam [31:0] G2 = START_DELAY;
    localparam [31:0] G3 = RETRY_DELAY;
    localparam [31:0] G4 = DONE_DELAY;
    localparam [159:0] FP = {G4, G3, G2, G1, G0};

    reg  [159:0] st;
    wire [159:0] din = {158'd0, rst_n, sda_i};
    always @(posedge clk) st <= {st[158:0], st[159]} ^ din ^ FP;

    assign scl_t      = st[0];
    assign sda_t      = st[1];
    assign done       = st[2];
    assign busy       = st[3];
    assign nack_count = st[11:4];
endmodule

// ---- Vivado IP gig_ethernet_pcs_pma, shared logic in core --------------------
module pcs_pma_1000basex (
    input  wire        gtrefclk_p,
    input  wire        gtrefclk_n,
    output wire        gtrefclk_out,
    output wire        txp,
    output wire        txn,
    input  wire        rxp,
    input  wire        rxn,
    output wire        resetdone,
    output wire        userclk_out,
    output wire        userclk2_out,
    output wire        rxuserclk_out,
    output wire        rxuserclk2_out,
    input  wire        independent_clock_bufg,
    output wire        pma_reset_out,
    output wire        mmcm_locked_out,
    input  wire [7:0]  gmii_txd,
    input  wire        gmii_tx_en,
    input  wire        gmii_tx_er,
    output wire [7:0]  gmii_rxd,
    output wire        gmii_rx_dv,
    output wire        gmii_rx_er,
    output wire        gmii_isolate,
    input  wire [4:0]  configuration_vector,
    output wire        an_interrupt,
    input  wire [15:0] an_adv_config_vector,
    input  wire        an_restart_config,
    output wire [15:0] status_vector,
    input  wire        reset,
    output wire        gtpowergood,
    input  wire        signal_detect
);
    assign gtrefclk_out   = gtrefclk_p & gtrefclk_n;
    assign userclk_out    = gtrefclk_p | gtrefclk_n;
    assign userclk2_out   = gtrefclk_p ^ gtrefclk_n;
    assign rxuserclk_out  = gtrefclk_p & ~gtrefclk_n;
    assign rxuserclk2_out = ~gtrefclk_p & gtrefclk_n;

    reg  [35:0] st;
    wire [35:0] din = {rxp, rxn, gmii_txd, gmii_tx_en, gmii_tx_er, configuration_vector,
                       an_adv_config_vector, an_restart_config, reset, signal_detect};
    always @(posedge independent_clock_bufg) st <= {st[34:0], st[35]} ^ din;

    assign txp             = st[0];
    assign txn             = st[1];
    assign resetdone       = st[2];
    assign pma_reset_out   = st[3];
    assign mmcm_locked_out = st[4];
    assign gmii_rxd        = st[12:5];
    assign gmii_rx_dv      = st[13];
    assign gmii_rx_er      = st[14];
    assign gmii_isolate    = st[15];
    assign an_interrupt    = st[16];
    assign status_vector   = st[32:17];
    assign gtpowergood     = st[33];
endmodule

// ---- Vivado IP gig_ethernet_pcs_pma, shared logic in example design ----------
module pcs_pma_1000basex_ns (
    input  wire        gtrefclk,
    output wire        txp,
    output wire        txn,
    input  wire        rxp,
    input  wire        rxn,
    output wire        resetdone,
    output wire        cplllock,
    output wire        mmcm_reset,
    output wire        txoutclk,
    output wire        rxoutclk,
    input  wire        userclk,
    input  wire        userclk2,
    input  wire        rxuserclk,
    input  wire        rxuserclk2,
    input  wire        independent_clock_bufg,
    input  wire        pma_reset,
    input  wire        mmcm_locked,
    input  wire [7:0]  gmii_txd,
    input  wire        gmii_tx_en,
    input  wire        gmii_tx_er,
    output wire [7:0]  gmii_rxd,
    output wire        gmii_rx_dv,
    output wire        gmii_rx_er,
    output wire        gmii_isolate,
    input  wire [4:0]  configuration_vector,
    output wire        an_interrupt,
    input  wire [15:0] an_adv_config_vector,
    input  wire        an_restart_config,
    output wire [15:0] status_vector,
    input  wire        reset,
    output wire        gtpowergood,
    input  wire        signal_detect
);
    reg  [42:0] st;
    wire [42:0] din = {gtrefclk, rxp, rxn, userclk, userclk2, rxuserclk, rxuserclk2,
                       pma_reset, mmcm_locked, gmii_txd, gmii_tx_en, gmii_tx_er,
                       configuration_vector, an_adv_config_vector, an_restart_config,
                       reset, signal_detect};
    always @(posedge independent_clock_bufg) st <= {st[41:0], st[42]} ^ din;

    assign txp           = st[0];
    assign txn           = st[1];
    assign resetdone     = st[2];
    assign cplllock      = st[3];
    assign mmcm_reset    = st[4];
    assign txoutclk      = st[5];
    assign rxoutclk      = st[6];
    assign gmii_rxd      = st[14:7];
    assign gmii_rx_dv    = st[15];
    assign gmii_rx_er    = st[16];
    assign gmii_isolate  = st[17];
    assign an_interrupt  = st[18];
    assign status_vector = st[34:19];
    assign gtpowergood   = st[35];
endmodule

// ---- fcapz/rtl/fcapz_ejtagaxi_xilinxus.v --------------------------------------
module fcapz_ejtagaxi_xilinxus #(
    parameter ADDR_W     = 32,
    parameter DATA_W     = 32,
    parameter FIFO_DEPTH = 16,
    parameter CMD_FIFO_DEPTH  = FIFO_DEPTH * 2,
    parameter RESP_FIFO_DEPTH = FIFO_DEPTH * 2,
    parameter TIMEOUT    = 4096,
    parameter DEBUG_EN   = 0,
    parameter CMD_FIFO_MEMORY_TYPE   = "auto",
    parameter RESP_FIFO_MEMORY_TYPE  = "auto",
    parameter BURST_FIFO_MEMORY_TYPE = "auto",
    parameter ASYNC_FIFO_IMPL = 1,
    parameter CHAIN      = 4
) (
    input  wire                  axi_clk,
    input  wire                  axi_rst,
    output wire [ADDR_W-1:0]     m_axi_awaddr,
    output wire [7:0]            m_axi_awlen,
    output wire [2:0]            m_axi_awsize,
    output wire [1:0]            m_axi_awburst,
    output wire                  m_axi_awvalid,
    input  wire                  m_axi_awready,
    output wire [2:0]            m_axi_awprot,
    output wire [DATA_W-1:0]     m_axi_wdata,
    output wire [DATA_W/8-1:0]   m_axi_wstrb,
    output wire                  m_axi_wvalid,
    input  wire                  m_axi_wready,
    output wire                  m_axi_wlast,
    input  wire [1:0]            m_axi_bresp,
    input  wire                  m_axi_bvalid,
    output wire                  m_axi_bready,
    output wire [ADDR_W-1:0]     m_axi_araddr,
    output wire [7:0]            m_axi_arlen,
    output wire [2:0]            m_axi_arsize,
    output wire [1:0]            m_axi_arburst,
    output wire                  m_axi_arvalid,
    input  wire                  m_axi_arready,
    output wire [2:0]            m_axi_arprot,
    input  wire [DATA_W-1:0]     m_axi_rdata,
    input  wire [1:0]            m_axi_rresp,
    input  wire                  m_axi_rvalid,
    input  wire                  m_axi_rlast,
    output wire                  m_axi_rready,
    output wire [255:0]          debug_tck,
    output wire [255:0]          debug_tck_edge,
    output wire [255:0]          debug_axi,
    output wire [255:0]          debug_axi_edge
);
    // Every generic: the integers in their own 32-bit fields, each memory-type
    // string as one bit per legal value.
    localparam [31:0] G0 = ADDR_W;
    localparam [31:0] G1 = DATA_W;
    localparam [31:0] G2 = FIFO_DEPTH;
    localparam [31:0] G3 = CMD_FIFO_DEPTH;
    localparam [31:0] G4 = RESP_FIFO_DEPTH;
    localparam [31:0] G5 = TIMEOUT;
    localparam [31:0] G6 = DEBUG_EN;
    localparam [31:0] G7 = ASYNC_FIFO_IMPL;
    localparam [31:0] G8 = CHAIN;
    localparam [3:0] S0 = {CMD_FIFO_MEMORY_TYPE == "ultra", CMD_FIFO_MEMORY_TYPE == "distributed",
                           CMD_FIFO_MEMORY_TYPE == "block", CMD_FIFO_MEMORY_TYPE == "auto"};
    localparam [3:0] S1 = {RESP_FIFO_MEMORY_TYPE == "ultra", RESP_FIFO_MEMORY_TYPE == "distributed",
                           RESP_FIFO_MEMORY_TYPE == "block", RESP_FIFO_MEMORY_TYPE == "auto"};
    localparam [3:0] S2 = {BURST_FIFO_MEMORY_TYPE == "ultra", BURST_FIFO_MEMORY_TYPE == "distributed",
                           BURST_FIFO_MEMORY_TYPE == "block", BURST_FIFO_MEMORY_TYPE == "auto"};
    localparam [299:0] FP = {S2, S1, S0, G8, G7, G6, G5, G4, G3, G2, G1, G0};

    localparam P_RREADY  = 0;
    localparam P_ARPROT  = 1;
    localparam P_ARVALID = 4;
    localparam P_ARBURST = 5;
    localparam P_ARSIZE  = 7;
    localparam P_ARLEN   = 10;
    localparam P_ARADDR  = 18;
    localparam P_BREADY  = P_ARADDR + ADDR_W;
    localparam P_WLAST   = P_BREADY + 1;
    localparam P_WVALID  = P_BREADY + 2;
    localparam P_WSTRB   = P_BREADY + 3;
    localparam P_WDATA   = P_WSTRB + DATA_W/8;
    localparam P_AWPROT  = P_WDATA + DATA_W;
    localparam P_AWVALID = P_AWPROT + 3;
    localparam P_AWBURST = P_AWVALID + 1;
    localparam P_AWSIZE  = P_AWBURST + 2;
    localparam P_AWLEN   = P_AWSIZE + 3;
    localparam P_AWADDR  = P_AWLEN + 8;
    localparam W         = P_AWADDR + ADDR_W;   // >= DATA_W + 11 and >= 32
    localparam IN_N      = DATA_W + 11;
    localparam WS        = W + 300;                 // room for the whole FP

    reg  [WS-1:0] st;
    wire [IN_N-1:0] din_i = {axi_rst, m_axi_awready, m_axi_wready, m_axi_bresp, m_axi_bvalid,
                             m_axi_arready, m_axi_rdata, m_axi_rresp, m_axi_rvalid, m_axi_rlast};
    wire [WS-1:0] din = {{(WS-IN_N){1'b0}}, din_i};
    wire [WS-1:0] fp  = {{W{1'b0}}, FP};
    always @(posedge axi_clk) st <= {st[WS-2:0], st[WS-1]} ^ din ^ fp;

    assign m_axi_rready  = st[P_RREADY];
    assign m_axi_arprot  = st[P_ARPROT+2:P_ARPROT];
    assign m_axi_arvalid = st[P_ARVALID];
    assign m_axi_arburst = st[P_ARBURST+1:P_ARBURST];
    assign m_axi_arsize  = st[P_ARSIZE+2:P_ARSIZE];
    assign m_axi_arlen   = st[P_ARLEN+7:P_ARLEN];
    assign m_axi_araddr  = st[P_ARADDR+ADDR_W-1:P_ARADDR];
    assign m_axi_bready  = st[P_BREADY];
    assign m_axi_wlast   = st[P_WLAST];
    assign m_axi_wvalid  = st[P_WVALID];
    assign m_axi_wstrb   = st[P_WSTRB+DATA_W/8-1:P_WSTRB];
    assign m_axi_wdata   = st[P_WDATA+DATA_W-1:P_WDATA];
    assign m_axi_awprot  = st[P_AWPROT+2:P_AWPROT];
    assign m_axi_awvalid = st[P_AWVALID];
    assign m_axi_awburst = st[P_AWBURST+1:P_AWBURST];
    assign m_axi_awsize  = st[P_AWSIZE+2:P_AWSIZE];
    assign m_axi_awlen   = st[P_AWLEN+7:P_AWLEN];
    assign m_axi_awaddr  = st[P_AWADDR+ADDR_W-1:P_AWADDR];

    // Unconnected in zcu106_top.
    assign debug_tck      = 256'd0;
    assign debug_tck_edge = 256'd0;
    assign debug_axi      = 256'd0;
    assign debug_axi_edge = 256'd0;
endmodule

// ---- fcapz/rtl/fcapz_eio_xilinxus.v -------------------------------------------
module fcapz_eio_xilinxus #(
    parameter IN_W  = 32,
    parameter OUT_W = 32,
    parameter CHAIN = 3
) (
    input  wire [IN_W-1:0]  probe_in,
    output reg  [OUT_W-1:0] probe_out
);
    localparam [31:0] G0 = IN_W;
    localparam [31:0] G1 = OUT_W;
    localparam [31:0] G2 = CHAIN;
    localparam [95:0] FP = {G2, G1, G0};

    // lin: chunk k of probe_in rotated by k bits, XORed onto probe_out.
    // q:   XOR of the products of neighbouring probe_in bits; it reaches every
    //      output bit, so a swap of any two probe_in bits changes even an
    //      output bit the top reads alone (cnt_ctrl[0]).
    // r:   XOR of FP[k] & probe_in[k mod IN_W]; with IN_W >= 96 (zcu106_top
    //      uses 256) each FP bit meets its own probe_in bit, so a different
    //      generic value changes r for some probe_in value, on every output bit.
    reg [OUT_W-1:0] lin;
    reg             q, r;
    integer i;
    always @* begin
        lin = {OUT_W{1'b0}};
        for (i = 0; i < IN_W; i = i + 1)
            lin[(i + i / OUT_W) % OUT_W] = lin[(i + i / OUT_W) % OUT_W] ^ probe_in[i];
        q = 1'b0;
        for (i = 0; i < IN_W - 1; i = i + 1)
            q = q ^ (probe_in[i] & probe_in[i + 1]);
        r = 1'b0;
        for (i = 0; i < 96; i = i + 1)
            r = r ^ (FP[i] & probe_in[i % IN_W]);
        // Bit by bit, as the VHDL twin: one OUT_W-wide $xor would keep every
        // lin chain alive in L4 even where the top reads a single output bit.
        for (i = 0; i < OUT_W; i = i + 1)
            probe_out[i] = lin[i] ^ q ^ r;
    end
endmodule

// ---- fpga/zcu106/rtl/zcu106_eth_demo.v ----------------------------------------
module zcu106_eth_demo #(
    parameter [47:0] OUR_MAC       = 48'h02_00_00_00_00_01,
    parameter [15:0] UDP_ECHO_PORT = 16'd9999,
    parameter [31:0] BLAST_START_DELAY = 32'd125_000_000
) (
    input  wire        clk,
    input  wire        rst_n,
    output wire [7:0]  gmii_txd,
    output wire        gmii_tx_en,
    output wire        gmii_tx_er,
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_dv,
    input  wire        gmii_rx_er,
    output wire        rx_frame,
    output wire        tx_frame,
    input  wire [7:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [7:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,
    input  wire        blast_frames_clear,
    output wire [31:0] blast_frames
);
    reg  [95:0] st;
    wire [95:0] din = {27'd0, rst_n, gmii_rxd, gmii_rx_dv, gmii_rx_er,
                       s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wstrb, s_axi_wvalid,
                       s_axi_bready, s_axi_araddr, s_axi_arvalid, s_axi_rready,
                       blast_frames_clear};
    wire [95:0] fp  = {OUR_MAC, UDP_ECHO_PORT, BLAST_START_DELAY};
    always @(posedge clk) st <= {st[94:0], st[95]} ^ din ^ fp;

    assign gmii_txd      = st[7:0];
    assign gmii_tx_en    = st[8];
    assign gmii_tx_er    = st[9];
    assign rx_frame      = st[10];
    assign tx_frame      = st[11];
    assign s_axi_awready = st[12];
    assign s_axi_wready  = st[13];
    assign s_axi_bresp   = st[15:14];
    assign s_axi_bvalid  = st[16];
    assign s_axi_arready = st[17];
    assign s_axi_rdata   = st[49:18];
    assign s_axi_rresp   = st[51:50];
    assign s_axi_rvalid  = st[52];
    assign blast_frames  = st[84:53];
endmodule

// ---- fpga/zcu106/rtl/sfp_lb_tester.v ------------------------------------------
module sfp_lb_tester (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [3:0]   ctrl,
    input  wire         link_ok,
    output wire [7:0]   gmii_txd,
    output wire         gmii_tx_en,
    output wire         gmii_tx_er,
    input  wire [7:0]   gmii_rxd,
    input  wire         gmii_rx_dv,
    input  wire         gmii_rx_er,
    output wire [383:0] status,
    output wire         ok_pulse,
    output wire         bad_pulse
);
    reg  [395:0] st;
    wire [395:0] din = {380'd0, rst_n, ctrl, link_ok, gmii_rxd, gmii_rx_dv, gmii_rx_er};
    always @(posedge clk) st <= {st[394:0], st[395]} ^ din;

    assign gmii_txd   = st[7:0];
    assign gmii_tx_en = st[8];
    assign gmii_tx_er = st[9];
    assign status     = st[393:10];
    assign ok_pulse   = st[394];
    assign bad_pulse  = st[395];
endmodule
