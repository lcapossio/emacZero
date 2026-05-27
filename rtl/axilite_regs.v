// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// axilite_regs.v - AXI4-Lite slave register block for Ethernet MAC
// 32-bit registers at byte addresses 0x00-0x90.
// Verilog 2001
// =============================================================================
//
// Register Map:
//   0x00 VERSION    RO    {MAJOR[7:0], MINOR[7:0], ID[15:0]}; values come from
//                         rtl/version.vh (single source of truth, validated
//                         against sw/emaczero/emaczero.h and emaczero.core by
//                         build_and_test.py).
//   0x04 CTRL       RW    [0] tx_en  [1] rx_en  [2] promisc
//                         [4:3] speed (00=1G, 01=100M, 10=10M, 11=reserved)
//                         [5] full_duplex (RW; default 1) — INFORMATIONAL ONLY.
//                              The MAC implements full-duplex operation; there
//                              is no half-duplex CSMA/CD logic. Software may
//                              reflect the auto-negotiated mode here for
//                              status, but the bit has no functional effect.
//                         [6] jumbo_en  (allow >1518-byte frames)
//                         [7] tx_csum_off (runtime select when
//                              TX_CSUM_OFFLOAD=1)
//                         [8] passthrough (sniffer mode: bypass MAC filter and
//                              deliver frames with FCS / size errors anyway,
//                              still tagged via m_axis_terror)
//   0x08 STATUS     RO    [0] tx_active  [1] tx_fifo_busy  [2] mdio_busy
//   0x0C MAC_LO     RW    our_mac[31:0]
//   0x10 MAC_HI     RW    our_mac[47:32]  (upper 16 bits read as 0)
//   0x14 MDIO_CMD   RW    [4:0] reg  [9:5] phy  [10] write  [11] go (self-clear)
//                          [12] c45_en   (0=clause-22, 1=clause-45)
//                          [14:13] c45_op (when c45_en=1; 00=ADDR 01=WRITE
//                          10=READ-INC 11=READ; ignored in C22)
//   0x18 MDIO_WDATA RW    [15:0] write data
//   0x1C MDIO_RDATA RO    [15:0] read data
//   0x20 IRQ_EN     RW    [0] tx_done  [1] rx_frame  [2] mdio_done
//   0x24 IRQ_STATUS W1C   [0] tx_done  [1] rx_frame  [2] mdio_done
//   0x28 TX_FRAME   RO/WC write-any-to-clear
//   0x2C TX_BYTE    RO/WC write-any-to-clear
//   0x30 RX_FRAME   RO/WC write-any-to-clear
//   0x34 RX_BYTE    RO/WC write-any-to-clear
//   0x38 RX_ERR     RO/WC write-any-to-clear
//   0x3C SCRATCH    RW
//   --- Only present when MCAST_HASH_FILTER == 1 ---
//   0x44 MCAST_LO   RW    mcast_hash_table[31:0]
//   0x48 MCAST_HI   RW    mcast_hash_table[63:32]
//   --- 802.3x PAUSE flow control (always present) ---
//   0x84 PAUSE_CTRL  RW    [0] tx_send (W1S, hardware self-clears once frame
//                              has been emitted)
//                          [1] rx_en   (honor incoming PAUSE frames)
//   0x88 PAUSE_QUANTA RW   [15:0] quanta to load into the next emitted frame
//   0x8C PAUSE_RX_CNT RO/WC count of received PAUSE frames
//   0x90 PAUSE_TX_CNT RO/WC count of transmitted PAUSE frames
//   --- RX statistics breakdown (always present) ---
//   0x4C RX_ERR_ALIGN    RO/WC  rx_er asserted during frame
//   0x50 RX_ERR_OVERFLOW RO/WC  RX FIFO overflow during frame
//   0x54 RX_ERR_OVERSIZE RO/WC  frame longer than current MAX (std/jumbo)
//   0x58 RX_BCAST        RO/WC  bcast frames received (dst = FF:FF:FF:FF:FF:FF)
//   0x5C RX_MCAST        RO/WC  mcast frames received (I/G bit set, !bcast)
//   0x60 RX_SIZE_64        RO/WC  frames exactly 64 bytes (incl FCS)
//   0x64 RX_SIZE_65_127    RO/WC
//   0x68 RX_SIZE_128_255   RO/WC
//   0x6C RX_SIZE_256_511   RO/WC
//   0x70 RX_SIZE_512_1023  RO/WC
//   0x74 RX_SIZE_1024_1518 RO/WC
//   0x78 RX_SIZE_JUMBO     RO/WC  > 1518 bytes
// =============================================================================

`include "version.vh"

module axilite_regs #(
    parameter ADDR_WIDTH        = 8,    // 8 bits gives 256-byte CSR space
    parameter MCAST_HASH_FILTER = 0
)(
    input  wire                    s_axi_aclk,
    input  wire                    s_axi_aresetn,

    // ---- AXI4-Lite Write Address ----
    input  wire [ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  wire                    s_axi_awvalid,
    output wire                    s_axi_awready,

    // ---- AXI4-Lite Write Data ----
    input  wire [31:0]             s_axi_wdata,
    input  wire [3:0]              s_axi_wstrb,
    input  wire                    s_axi_wvalid,
    output wire                    s_axi_wready,

    // ---- AXI4-Lite Write Response ----
    output wire [1:0]              s_axi_bresp,
    output reg                     s_axi_bvalid,
    input  wire                    s_axi_bready,

    // ---- AXI4-Lite Read Address ----
    input  wire [ADDR_WIDTH-1:0]   s_axi_araddr,
    input  wire                    s_axi_arvalid,
    output reg                     s_axi_arready,

    // ---- AXI4-Lite Read Data ----
    output reg  [31:0]             s_axi_rdata,
    output wire [1:0]              s_axi_rresp,
    output reg                     s_axi_rvalid,
    input  wire                    s_axi_rready,

    // ---- Configuration outputs ----
    output wire        cfg_tx_en,
    output wire        cfg_rx_en,
    output wire        cfg_promisc,
    output wire [1:0]  cfg_speed,        // 00=1G, 01=100M, 10=10M
    output wire        cfg_full_duplex,
    output wire        cfg_jumbo_en,
    output wire        cfg_tx_csum_off,
    output wire        cfg_passthrough,
    output wire [47:0] cfg_mac_addr,
    output wire [63:0] cfg_mcast_hash_table,

    // ---- PAUSE controls ----
    output wire        cfg_pause_rx_en,
    output reg         cfg_pause_tx_send,    // single-cycle pulse
    output wire [15:0] cfg_pause_tx_quanta,
    input  wire [31:0] stat_pause_rx_cnt,
    input  wire [31:0] stat_pause_tx_cnt,
    output reg         stat_clr_pause,

    // ---- MDIO interface ----
    output reg         mdio_go,
    output wire        mdio_write,
    output wire [4:0]  mdio_phy_addr,
    output wire [4:0]  mdio_reg_addr,
    output wire [15:0] mdio_wdata,
    output wire        mdio_c45_en,
    output wire [1:0]  mdio_c45_op,
    input  wire [15:0] mdio_rdata,
    input  wire        mdio_done,
    input  wire        mdio_busy,

    // ---- Statistics inputs ----
    input  wire [31:0] stat_tx_frame_cnt,
    input  wire [31:0] stat_tx_byte_cnt,
    input  wire [31:0] stat_rx_frame_cnt,
    input  wire [31:0] stat_rx_byte_cnt,
    input  wire [31:0] stat_rx_err_cnt,        // legacy: rx_crc_err_cnt
    input  wire [31:0] stat_rx_err_align_cnt,
    input  wire [31:0] stat_rx_err_overflow_cnt,
    input  wire [31:0] stat_rx_err_oversize_cnt,
    input  wire [31:0] stat_rx_bcast_cnt,
    input  wire [31:0] stat_rx_mcast_cnt,
    input  wire [31:0] stat_rx_size_64_cnt,
    input  wire [31:0] stat_rx_size_65_127_cnt,
    input  wire [31:0] stat_rx_size_128_255_cnt,
    input  wire [31:0] stat_rx_size_256_511_cnt,
    input  wire [31:0] stat_rx_size_512_1023_cnt,
    input  wire [31:0] stat_rx_size_1024_1518_cnt,
    input  wire [31:0] stat_rx_size_jumbo_cnt,
    output reg         stat_clr_tx,
    output reg         stat_clr_rx,

    // ---- Status inputs ----
    input  wire        sts_tx_active,
    input  wire        sts_tx_fifo_busy,

    // ---- Interrupt event inputs (single-cycle pulses) ----
    input  wire        evt_tx_done,
    input  wire        evt_rx_frame,

    // ---- Interrupt output ----
    output wire        irq
);

    // =========================================================================
    // Constants
    // =========================================================================
    localparam [31:0] VERSION = {`EMZ_VERSION_MAJOR,
                                 `EMZ_VERSION_MINOR,
                                 `EMZ_VERSION_ID};

    // Register address offsets (word-aligned, using bits [ADDR_WIDTH-1:2])
    localparam [5:0] A_VERSION    = 6'h00;  // 0x00
    localparam [5:0] A_CTRL       = 6'h01;  // 0x04
    localparam [5:0] A_STATUS     = 6'h02;  // 0x08
    localparam [5:0] A_MAC_LO     = 6'h03;  // 0x0C
    localparam [5:0] A_MAC_HI     = 6'h04;  // 0x10
    localparam [5:0] A_MDIO_CMD   = 6'h05;  // 0x14
    localparam [5:0] A_MDIO_WDATA = 6'h06;  // 0x18
    localparam [5:0] A_MDIO_RDATA = 6'h07;  // 0x1C
    localparam [5:0] A_IRQ_EN     = 6'h08;  // 0x20
    localparam [5:0] A_IRQ_STATUS = 6'h09;  // 0x24
    localparam [5:0] A_TX_FRAME   = 6'h0A;  // 0x28
    localparam [5:0] A_TX_BYTE    = 6'h0B;  // 0x2C
    localparam [5:0] A_RX_FRAME   = 6'h0C;  // 0x30
    localparam [5:0] A_RX_BYTE    = 6'h0D;  // 0x34
    localparam [5:0] A_RX_ERR     = 6'h0E;  // 0x38
    localparam [5:0] A_SCRATCH    = 6'h0F;  // 0x3C
    // MCAST registers (only active when MCAST_HASH_FILTER == 1)
    localparam [5:0] A_MCAST_LO   = 6'h11;  // 0x44
    localparam [5:0] A_MCAST_HI   = 6'h12;  // 0x48
    // RX statistics breakdown
    localparam [5:0] A_RX_ERR_ALIGN     = 6'h13;  // 0x4C
    localparam [5:0] A_RX_ERR_OVERFLOW  = 6'h14;  // 0x50
    localparam [5:0] A_RX_ERR_OVERSIZE  = 6'h15;  // 0x54
    localparam [5:0] A_RX_BCAST         = 6'h16;  // 0x58
    localparam [5:0] A_RX_MCAST         = 6'h17;  // 0x5C
    localparam [5:0] A_RX_SIZE_64       = 6'h18;  // 0x60
    localparam [5:0] A_RX_SIZE_65_127   = 6'h19;  // 0x64
    localparam [5:0] A_RX_SIZE_128_255  = 6'h1A;  // 0x68
    localparam [5:0] A_RX_SIZE_256_511  = 6'h1B;  // 0x6C
    localparam [5:0] A_RX_SIZE_512_1023 = 6'h1C;  // 0x70
    localparam [5:0] A_RX_SIZE_1024_1518= 6'h1D;  // 0x74
    localparam [5:0] A_RX_SIZE_JUMBO    = 6'h1E;  // 0x78
    // PAUSE registers (require ADDR_WIDTH >= 8)
    localparam [5:0] A_PAUSE_CTRL    = 6'h21;  // 0x84
    localparam [5:0] A_PAUSE_QUANTA  = 6'h22;  // 0x88
    localparam [5:0] A_PAUSE_RX_CNT  = 6'h23;  // 0x8C
    localparam [5:0] A_PAUSE_TX_CNT  = 6'h24;  // 0x90

    // =========================================================================
    // Responses always OKAY
    // =========================================================================
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // =========================================================================
    // Registers
    // =========================================================================
    // [0] tx_en, [1] rx_en, [2] promisc, [4:3] speed, [5] full_duplex,
    // [6] jumbo_en, [7] tx_csum_off, [8] passthrough
    reg  [8:0]  reg_ctrl;
    reg  [31:0] reg_mac_lo;
    reg  [15:0] reg_mac_hi;
    // Storage mirrors user bit positions exactly. Bit 11 (go) self-clears and
    // is captured separately via mdio_go, so bit 11 of this register reads 0.
    reg  [14:0] reg_mdio_cmd;   // [4:0] reg/devad, [9:5] phy, [10] write,
                                // [11] reads-as-0, [12] c45_en, [14:13] c45_op
    reg  [15:0] reg_mdio_wdata;
    reg  [2:0]  reg_irq_en;
    reg  [2:0]  reg_irq_status;
    reg  [31:0] reg_scratch;
    reg  [31:0] reg_mcast_lo;   // mcast_hash_table[31:0]
    reg  [31:0] reg_mcast_hi;   // mcast_hash_table[63:32]
    // PAUSE
    reg         reg_pause_rx_en;
    reg  [15:0] reg_pause_quanta;

    // =========================================================================
    // Configuration outputs
    // =========================================================================
    assign cfg_tx_en       = reg_ctrl[0];
    assign cfg_rx_en       = reg_ctrl[1];
    assign cfg_promisc     = reg_ctrl[2];
    assign cfg_speed       = reg_ctrl[4:3];
    assign cfg_full_duplex = reg_ctrl[5];
    assign cfg_jumbo_en    = reg_ctrl[6];
    assign cfg_tx_csum_off = reg_ctrl[7];
    assign cfg_passthrough = reg_ctrl[8];
    assign cfg_mac_addr    = {reg_mac_hi, reg_mac_lo};
    assign cfg_mcast_hash_table = MCAST_HASH_FILTER ?
                                  {reg_mcast_hi, reg_mcast_lo} : 64'h0;
    assign cfg_pause_rx_en      = reg_pause_rx_en;
    assign cfg_pause_tx_quanta  = reg_pause_quanta;

    // =========================================================================
    // MDIO outputs
    // =========================================================================
    assign mdio_reg_addr = reg_mdio_cmd[4:0];
    assign mdio_phy_addr = reg_mdio_cmd[9:5];
    assign mdio_write    = reg_mdio_cmd[10];
    assign mdio_c45_en   = reg_mdio_cmd[12];
    assign mdio_c45_op   = reg_mdio_cmd[14:13];
    assign mdio_wdata    = reg_mdio_wdata;

    // =========================================================================
    // Interrupt logic
    // =========================================================================
    assign irq = |(reg_irq_status & reg_irq_en);

    // =========================================================================
    // Write channel — AW and W accepted independently per AXI4-Lite spec
    // =========================================================================
    reg        aw_ready_r;
    reg        w_ready_r;
    reg        aw_latched;       // AW received, waiting for W
    reg        w_latched;        // W received, waiting for AW
    reg [ADDR_WIDTH-1:0] aw_addr;
    reg [31:0] w_data;
    reg [3:0]  w_strb;

    assign s_axi_awready = aw_ready_r;
    assign s_axi_wready  = w_ready_r;

    // Write fires when both AW and W have been received
    wire                  wr_fire = (aw_latched && w_latched);
    wire [ADDR_WIDTH-3:0]  wr_idx  = aw_addr[ADDR_WIDTH-1:2];

    // WSTRB byte-lane merge helper
    function [31:0] strb_merge;
        input [31:0] old_val;
        input [31:0] new_val;
        input [3:0]  strb;
        begin
            strb_merge = {strb[3] ? new_val[31:24] : old_val[31:24],
                          strb[2] ? new_val[23:16] : old_val[23:16],
                          strb[1] ? new_val[15:8]  : old_val[15:8],
                          strb[0] ? new_val[7:0]   : old_val[7:0]};
        end
    endfunction

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            aw_ready_r     <= 1'b1;
            w_ready_r      <= 1'b1;
            s_axi_bvalid   <= 1'b0;
            aw_latched     <= 1'b0;
            w_latched      <= 1'b0;
            aw_addr        <= {ADDR_WIDTH{1'b0}};
            w_data         <= 32'd0;
            w_strb         <= 4'd0;

            // tx_en=1, rx_en=1, promisc=0, speed=00 (1G), full_duplex=1,
            // jumbo_en=0, tx_csum_off=0, passthrough=0
            reg_ctrl       <= 9'b0_0010_0011;
            reg_mac_lo     <= 32'h00_00_00_01;
            reg_mac_hi     <= 16'h02_00;  // locally administered
            reg_mdio_cmd   <= 15'd0;
            reg_mdio_wdata <= 16'd0;
            reg_irq_en     <= 3'd0;
            reg_irq_status <= 3'd0;
            reg_scratch    <= 32'd0;
            reg_mcast_lo   <= 32'd0;
            reg_mcast_hi   <= 32'd0;
            mdio_go        <= 1'b0;
            stat_clr_tx    <= 1'b0;
            stat_clr_rx    <= 1'b0;
            stat_clr_pause <= 1'b0;
            cfg_pause_tx_send <= 1'b0;
            reg_pause_rx_en  <= 1'b0;
            reg_pause_quanta <= 16'd0;
        end else begin
            // Self-clearing pulses default to 0
            mdio_go     <= 1'b0;
            stat_clr_tx <= 1'b0;
            stat_clr_rx <= 1'b0;
            stat_clr_pause   <= 1'b0;
            cfg_pause_tx_send <= 1'b0;

            // IRQ event capture (set bits from event pulses)
            if (evt_tx_done)  reg_irq_status[0] <= 1'b1;
            if (evt_rx_frame) reg_irq_status[1] <= 1'b1;
            if (mdio_done)    reg_irq_status[2] <= 1'b1;

            // --- AW handshake (independent of W) ---
            if (s_axi_awvalid && aw_ready_r) begin
                aw_addr    <= s_axi_awaddr;
                aw_latched <= 1'b1;
                aw_ready_r <= 1'b0;
            end

            // --- W handshake (independent of AW) ---
            if (s_axi_wvalid && w_ready_r) begin
                w_data     <= s_axi_wdata;
                w_strb     <= s_axi_wstrb;
                w_latched  <= 1'b1;
                w_ready_r  <= 1'b0;
            end

            // --- Both received: execute write + issue B ---
            if (wr_fire && !s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1;
                aw_latched   <= 1'b0;
                w_latched    <= 1'b0;

                case (wr_idx)
                    A_CTRL:       reg_ctrl       <= strb_merge({23'd0, reg_ctrl}, w_data, w_strb);
                    A_MAC_LO:     reg_mac_lo     <= strb_merge(reg_mac_lo, w_data, w_strb);
                    A_MAC_HI:     reg_mac_hi     <= strb_merge({16'd0, reg_mac_hi}, w_data, w_strb);
                    A_MDIO_CMD: begin
                        // Mask bit 11 (go) to 0 so it never persists in storage
                        reg_mdio_cmd <= strb_merge({17'd0, reg_mdio_cmd}, w_data, w_strb)
                                        & 15'h77FF;
                        if (w_strb[1] && w_data[11] && !mdio_busy)
                            mdio_go <= 1'b1;
                    end
                    A_MDIO_WDATA: reg_mdio_wdata <= strb_merge({16'd0, reg_mdio_wdata}, w_data, w_strb);
                    A_IRQ_EN:     reg_irq_en     <= strb_merge({29'd0, reg_irq_en}, w_data, w_strb);
                    A_IRQ_STATUS: reg_irq_status <= reg_irq_status & ~w_data[2:0]; // W1C
                    A_TX_FRAME:   stat_clr_tx    <= 1'b1;
                    A_TX_BYTE:    stat_clr_tx    <= 1'b1;
                    A_RX_FRAME:   stat_clr_rx    <= 1'b1;
                    A_RX_BYTE:    stat_clr_rx    <= 1'b1;
                    A_RX_ERR:     stat_clr_rx    <= 1'b1;
                    A_SCRATCH:    reg_scratch    <= strb_merge(reg_scratch, w_data, w_strb);
                    A_MCAST_LO: if (MCAST_HASH_FILTER)
                                    reg_mcast_lo <= strb_merge(reg_mcast_lo, w_data, w_strb);
                    A_MCAST_HI: if (MCAST_HASH_FILTER)
                                    reg_mcast_hi <= strb_merge(reg_mcast_hi, w_data, w_strb);
                    // Extended RX stat counters: any write clears (W1C-style,
                    // grouped under stat_clr_rx since they all live in eth_stats RX block)
                    A_RX_ERR_ALIGN,
                    A_RX_ERR_OVERFLOW,
                    A_RX_ERR_OVERSIZE,
                    A_RX_BCAST,
                    A_RX_MCAST,
                    A_RX_SIZE_64,
                    A_RX_SIZE_65_127,
                    A_RX_SIZE_128_255,
                    A_RX_SIZE_256_511,
                    A_RX_SIZE_512_1023,
                    A_RX_SIZE_1024_1518,
                    A_RX_SIZE_JUMBO: stat_clr_rx <= 1'b1;
                    A_PAUSE_CTRL: begin
                        if (w_strb[0]) begin
                            // [0] tx_send (W1S, self-clearing pulse to eth_pause)
                            // [1] rx_en   (level-sensitive)
                            if (w_data[0]) cfg_pause_tx_send <= 1'b1;
                            reg_pause_rx_en <= w_data[1];
                        end
                    end
                    A_PAUSE_QUANTA: begin
                        if (w_strb[0]) reg_pause_quanta[7:0]  <= w_data[7:0];
                        if (w_strb[1]) reg_pause_quanta[15:8] <= w_data[15:8];
                    end
                    A_PAUSE_RX_CNT,
                    A_PAUSE_TX_CNT: stat_clr_pause <= 1'b1;
                    default: ;  // STATUS, MDIO_RDATA, VERSION: read-only
                endcase
            end

            // --- B handshake ---
            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
                aw_ready_r   <= 1'b1;
                w_ready_r    <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Read channel
    // =========================================================================
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
        end else begin
            if (s_axi_arvalid && !s_axi_rvalid && !s_axi_arready) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;

                case (s_axi_araddr[ADDR_WIDTH-1:2])  // ADDR_WIDTH-2 bit index
                    A_CTRL:       s_axi_rdata <= {23'd0, reg_ctrl};
                    A_STATUS:     s_axi_rdata <= {29'd0, mdio_busy, sts_tx_fifo_busy, sts_tx_active};
                    A_MAC_LO:     s_axi_rdata <= reg_mac_lo;
                    A_MAC_HI:     s_axi_rdata <= {16'd0, reg_mac_hi};
                    A_MDIO_CMD:   s_axi_rdata <= {17'd0, reg_mdio_cmd}; // bit 11 (go) reads 0 by storage
                    A_MDIO_WDATA: s_axi_rdata <= {16'd0, reg_mdio_wdata};
                    A_MDIO_RDATA: s_axi_rdata <= {16'd0, mdio_rdata};
                    A_IRQ_EN:     s_axi_rdata <= {29'd0, reg_irq_en};
                    A_IRQ_STATUS: s_axi_rdata <= {29'd0, reg_irq_status};
                    A_TX_FRAME:   s_axi_rdata <= stat_tx_frame_cnt;
                    A_TX_BYTE:    s_axi_rdata <= stat_tx_byte_cnt;
                    A_RX_FRAME:   s_axi_rdata <= stat_rx_frame_cnt;
                    A_RX_BYTE:    s_axi_rdata <= stat_rx_byte_cnt;
                    A_RX_ERR:     s_axi_rdata <= stat_rx_err_cnt;
                    A_SCRATCH:    s_axi_rdata <= reg_scratch;
                    A_VERSION:    s_axi_rdata <= VERSION;
                    A_MCAST_LO:   s_axi_rdata <= MCAST_HASH_FILTER ? reg_mcast_lo : 32'd0;
                    A_MCAST_HI:   s_axi_rdata <= MCAST_HASH_FILTER ? reg_mcast_hi : 32'd0;
                    A_RX_ERR_ALIGN:      s_axi_rdata <= stat_rx_err_align_cnt;
                    A_RX_ERR_OVERFLOW:   s_axi_rdata <= stat_rx_err_overflow_cnt;
                    A_RX_ERR_OVERSIZE:   s_axi_rdata <= stat_rx_err_oversize_cnt;
                    A_RX_BCAST:          s_axi_rdata <= stat_rx_bcast_cnt;
                    A_RX_MCAST:          s_axi_rdata <= stat_rx_mcast_cnt;
                    A_RX_SIZE_64:        s_axi_rdata <= stat_rx_size_64_cnt;
                    A_RX_SIZE_65_127:    s_axi_rdata <= stat_rx_size_65_127_cnt;
                    A_RX_SIZE_128_255:   s_axi_rdata <= stat_rx_size_128_255_cnt;
                    A_RX_SIZE_256_511:   s_axi_rdata <= stat_rx_size_256_511_cnt;
                    A_RX_SIZE_512_1023:  s_axi_rdata <= stat_rx_size_512_1023_cnt;
                    A_RX_SIZE_1024_1518: s_axi_rdata <= stat_rx_size_1024_1518_cnt;
                    A_RX_SIZE_JUMBO:     s_axi_rdata <= stat_rx_size_jumbo_cnt;
                    A_PAUSE_CTRL:        s_axi_rdata <= {30'd0, reg_pause_rx_en, 1'b0};
                    A_PAUSE_QUANTA:      s_axi_rdata <= {16'd0, reg_pause_quanta};
                    A_PAUSE_RX_CNT:      s_axi_rdata <= stat_pause_rx_cnt;
                    A_PAUSE_TX_CNT:      s_axi_rdata <= stat_pause_tx_cnt;
                    default:      s_axi_rdata <= 32'd0;
                endcase
            end else begin
                s_axi_arready <= 1'b0;
            end

            if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
