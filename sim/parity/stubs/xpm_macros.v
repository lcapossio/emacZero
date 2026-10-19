// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// xpm_macros.v - Parity-only behavioural stubs of the Xilinx XPM macros
// xpm_fifo_async and xpm_memory_sdpram.
// Read on the Verilog (golden) side of a translateHDL proof in place of the
// Vivado XPM library; xpm_macros.vhd is the line-for-line VHDL twin read on
// the candidate side (same state names, so the proof pairs it). Parameters and
// ports match Vivado's xpm_VCOMP.vhd, so the proof checks every connection the
// design makes and every parameter value listed as "modelled" below.
//
// NOT the vendor models, and NOT cycle-accurate to them. The proof that uses
// them shows the Verilog and VHDL designs are equivalent *given the same
// macro behaviour*; it says nothing about the real macro.
//
// xpm_fifo_async - modelled: FIFO_WRITE_DEPTH (occupancy width, full),
//   READ_MODE ("fwft" with the one-cycle data_valid bubble after each pop of
//   sim/tb/xpm_fifo_async_model.v, else "std"), CDC_SYNC_STAGES (length of
//   wr_rst_busy / rd_rst_busy after rst), FULL_RESET_VALUE, DOUT_RESET_VALUE,
//   PROG_FULL_THRESH, PROG_EMPTY_THRESH, WR/RD_DATA_COUNT_WIDTH (MSBs of the
//   occupancy) and USE_ADV_FEATURES (each optional output is 0 unless its
//   feature bit is set). Storage is only 4 words (addressed by the low two
//   pointer bits, so data aliases past 4 words) to keep the proof small.
//   Occupancy is one combinational count across both clocks. Not modelled:
//   FIFO_READ_LATENCY, FIFO_MEMORY_TYPE, CASCADE_HEIGHT, RELATED_CLOCKS,
//   ECC (inject*/sbiterr/dbiterr are 0), SIM_ASSERT_CHK, EN_SIM_ASSERT_ERR,
//   WAKEUP_TIME / sleep.
// xpm_memory_sdpram - modelled: MEMORY_SIZE / WRITE_DATA_WIDTH_A (depth:
//   writes at or past it are dropped; storage itself is only 8 words, indexed
//   by the low three address bits, so data aliases past 8 words),
//   port widths, CLOCKING_MODE (read port on clka for "common_clock"),
//   READ_LATENCY_B (1, or 2 with regceb on the second stage), READ_RESET_VALUE_B
//   (rstb), WRITE_MODE_B ("read_first", "write_first", else no_change), wea
//   bit 0 as the write enable. Not modelled: everything else (ECC, init,
//   sleep, primitive and optimisation hints, RST_MODE_*).
// Verilog 2001
// =============================================================================

module xpm_fifo_async #(
    parameter         FIFO_MEMORY_TYPE    = "auto",
    parameter integer FIFO_WRITE_DEPTH    = 2048,
    parameter integer CASCADE_HEIGHT      = 0,
    parameter integer RELATED_CLOCKS      = 0,
    parameter integer WRITE_DATA_WIDTH    = 32,
    parameter         READ_MODE           = "std",
    parameter integer FIFO_READ_LATENCY   = 1,
    parameter integer FULL_RESET_VALUE    = 0,
    parameter         USE_ADV_FEATURES    = "0707",
    parameter integer READ_DATA_WIDTH     = 32,
    parameter integer CDC_SYNC_STAGES     = 2,
    parameter integer WR_DATA_COUNT_WIDTH = 1,
    parameter integer PROG_FULL_THRESH    = 10,
    parameter integer RD_DATA_COUNT_WIDTH = 1,
    parameter integer PROG_EMPTY_THRESH   = 10,
    parameter         DOUT_RESET_VALUE    = "0",
    parameter         ECC_MODE            = "no_ecc",
    parameter integer SIM_ASSERT_CHK      = 0,
    parameter         EN_SIM_ASSERT_ERR   = "warning",
    parameter integer WAKEUP_TIME         = 0
)(
    input  wire                           sleep,
    input  wire                           rst,
    input  wire                           wr_clk,
    input  wire                           wr_en,
    input  wire [WRITE_DATA_WIDTH-1:0]    din,
    output wire                           full,
    output wire                           prog_full,
    output wire [WR_DATA_COUNT_WIDTH-1:0] wr_data_count,
    output wire                           overflow,
    output wire                           wr_rst_busy,
    output wire                           almost_full,
    output wire                           wr_ack,
    input  wire                           rd_clk,
    input  wire                           rd_en,
    output wire [READ_DATA_WIDTH-1:0]     dout,
    output wire                           empty,
    output wire                           prog_empty,
    output wire [RD_DATA_COUNT_WIDTH-1:0] rd_data_count,
    output wire                           underflow,
    output wire                           rd_rst_busy,
    output wire                           almost_empty,
    output wire                           data_valid,
    input  wire                           injectsbiterr,
    input  wire                           injectdbiterr,
    output wire                           sbiterr,
    output wire                           dbiterr
);
    function integer clog2;
        input integer value;
        integer tmp;
        begin
            tmp = value - 1;
            for (clog2 = 0; tmp > 0; clog2 = clog2 + 1)
                tmp = tmp >> 1;
        end
    endfunction

    function [3:0] hex_nibble;
        input [7:0] c;
        begin
            if (c >= "0" && c <= "9")      hex_nibble = c - "0";
            else if (c >= "a" && c <= "f") hex_nibble = c - "a" + 8'd10;
            else if (c >= "A" && c <= "F") hex_nibble = c - "A" + 8'd10;
            else                           hex_nibble = 4'd0;
        end
    endfunction

    // Up to 4 hex digits (rightmost = least significant) -> 16 bits.
    function [15:0] hex16;
        input [31:0] s;
        begin
            hex16 = {hex_nibble(s[31:24]), hex_nibble(s[23:16]),
                     hex_nibble(s[15:8]),  hex_nibble(s[7:0])};
        end
    endfunction

    localparam integer CW   = clog2(FIFO_WRITE_DEPTH) + 1;   // occupancy width
    localparam [15:0]  ADV  = hex16(USE_ADV_FEATURES);
    localparam         FWFT = (READ_MODE == "fwft") || (READ_MODE == "FWFT");
    localparam [READ_DATA_WIDTH-1:0] DOUT_RST = hex16(DOUT_RESET_VALUE);

    reg  [CW-1:0]               wr_cnt;        // words written (wr_clk)
    reg  [CW-1:0]               rd_cnt;        // words popped (rd_clk)
    reg  [3:0]                  wr_busy_cnt;   // wr_rst_busy countdown
    reg  [3:0]                  rd_busy_cnt;   // rd_rst_busy countdown
    reg                         ovf_r;
    reg                         ack_r;
    reg                         unf_r;
    reg                         dv_r;
    reg                         bubble;
    reg  [READ_DATA_WIDTH-1:0]  dout_r;
    reg  [WRITE_DATA_WIDTH-1:0] mem0, mem1, mem2, mem3;

    wire [CW-1:0] count     = wr_cnt - rd_cnt;
    wire          cnt_empty = (count == {CW{1'b0}});
    wire          cnt_full  = (count == FIFO_WRITE_DEPTH);
    wire          wr_busy   = (wr_busy_cnt != 4'd0);
    wire          rd_busy   = (rd_busy_cnt != 4'd0);
    wire [WRITE_DATA_WIDTH-1:0] mem_rd =
        (rd_cnt[1:0] == 2'd0) ? mem0 :
        (rd_cnt[1:0] == 2'd1) ? mem1 :
        (rd_cnt[1:0] == 2'd2) ? mem2 : mem3;

    assign full      = wr_busy ? (FULL_RESET_VALUE != 0) : cnt_full;
    assign empty     = rd_busy | cnt_empty;
    wire   can_write = wr_en & ~wr_busy & ~cnt_full;
    wire   can_read  = rd_en & ~empty;

    always @(posedge wr_clk or posedge rst) begin
        if (rst) begin
            wr_cnt      <= {CW{1'b0}};
            wr_busy_cnt <= CDC_SYNC_STAGES;
            ovf_r       <= 1'b0;
            ack_r       <= 1'b0;
        end else begin
            if (wr_busy)
                wr_busy_cnt <= wr_busy_cnt - 4'd1;
            ovf_r <= wr_en & full;
            ack_r <= can_write;
            if (can_write)
                wr_cnt <= wr_cnt + 1'b1;
        end
    end

    always @(posedge wr_clk) begin
        if (can_write) begin
            case (wr_cnt[1:0])
                2'd0:    mem0 <= din;
                2'd1:    mem1 <= din;
                2'd2:    mem2 <= din;
                default: mem3 <= din;
            endcase
        end
    end

    always @(posedge rd_clk or posedge rst) begin
        if (rst) begin
            rd_cnt      <= {CW{1'b0}};
            rd_busy_cnt <= CDC_SYNC_STAGES;
            unf_r       <= 1'b0;
            dv_r        <= 1'b0;
            bubble      <= 1'b0;
            dout_r      <= DOUT_RST;
        end else begin
            if (rd_busy)
                rd_busy_cnt <= rd_busy_cnt - 4'd1;
            unf_r <= rd_en & empty;
            if (can_read)
                rd_cnt <= rd_cnt + 1'b1;
            if (FWFT) begin
                // After a pop data_valid drops for one rd_clk before the next
                // word is presented (sim/tb/xpm_fifo_async_model.v).
                if (can_read) begin
                    dv_r   <= 1'b0;
                    bubble <= 1'b1;
                end else begin
                    bubble <= 1'b0;
                    dv_r   <= ~cnt_empty;
                    if (~cnt_empty)
                        dout_r <= mem_rd;
                end
            end else begin
                dv_r <= can_read;
                if (can_read)
                    dout_r <= mem_rd;
            end
        end
    end

    assign dout          = dout_r;
    assign wr_rst_busy   = wr_busy;
    assign rd_rst_busy   = rd_busy;
    assign overflow      = ADV[0]  & ovf_r;
    assign prog_full     = ADV[1]  & (count >= PROG_FULL_THRESH);
    assign wr_data_count = ADV[2]  ? count[CW-1 -: WR_DATA_COUNT_WIDTH] : {WR_DATA_COUNT_WIDTH{1'b0}};
    assign almost_full   = ADV[3]  & (count >= FIFO_WRITE_DEPTH - 1);
    assign wr_ack        = ADV[4]  & ack_r;
    assign underflow     = ADV[8]  & unf_r;
    assign prog_empty    = ADV[9]  & (rd_busy | (count <= PROG_EMPTY_THRESH));
    assign rd_data_count = ADV[10] ? count[CW-1 -: RD_DATA_COUNT_WIDTH] : {RD_DATA_COUNT_WIDTH{1'b0}};
    assign almost_empty  = ADV[11] & (count <= 1);
    assign data_valid    = ADV[12] & dv_r;
    assign sbiterr       = 1'b0;
    assign dbiterr       = 1'b0;

endmodule

module xpm_memory_sdpram #(
    parameter integer MEMORY_SIZE             = 2048,
    parameter         MEMORY_PRIMITIVE        = "auto",
    parameter         CLOCKING_MODE           = "common_clock",
    parameter         ECC_MODE                = "no_ecc",
    parameter         ECC_TYPE                = "none",
    parameter         ECC_BIT_RANGE           = "[7:0]",
    parameter         MEMORY_INIT_FILE        = "none",
    parameter         MEMORY_INIT_PARAM       = "",
    parameter integer USE_MEM_INIT            = 1,
    parameter integer USE_MEM_INIT_MMI        = 0,
    parameter         WAKEUP_TIME             = "disable_sleep",
    parameter integer AUTO_SLEEP_TIME         = 0,
    parameter integer MESSAGE_CONTROL         = 0,
    parameter integer USE_EMBEDDED_CONSTRAINT = 0,
    parameter         MEMORY_OPTIMIZATION     = "true",
    parameter integer CASCADE_HEIGHT          = 0,
    parameter integer SIM_ASSERT_CHK          = 0,
    parameter integer WRITE_PROTECT           = 1,
    parameter         RAM_DECOMP              = "auto",
    parameter integer IGNORE_INIT_SYNTH       = 0,
    parameter integer WRITE_DATA_WIDTH_A      = 32,
    parameter integer BYTE_WRITE_WIDTH_A      = 32,
    parameter integer ADDR_WIDTH_A            = 6,
    parameter         RST_MODE_A              = "SYNC",
    parameter integer READ_DATA_WIDTH_B       = 32,
    parameter integer ADDR_WIDTH_B            = 6,
    parameter         READ_RESET_VALUE_B      = "0",
    parameter integer READ_LATENCY_B          = 2,
    parameter         WRITE_MODE_B            = "no_change",
    parameter         RST_MODE_B              = "SYNC"
)(
    input  wire                                             sleep,
    input  wire                                             clka,
    input  wire                                             ena,
    input  wire [(WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A)-1:0] wea,
    input  wire [ADDR_WIDTH_A-1:0]                          addra,
    input  wire [WRITE_DATA_WIDTH_A-1:0]                    dina,
    input  wire                                             injectsbiterra,
    input  wire                                             injectdbiterra,
    input  wire                                             clkb,
    input  wire                                             rstb,
    input  wire                                             enb,
    input  wire                                             regceb,
    input  wire [ADDR_WIDTH_B-1:0]                          addrb,
    output wire [READ_DATA_WIDTH_B-1:0]                     doutb,
    output wire                                             sbiterrb,
    output wire                                             dbiterrb
);
    function [3:0] hex_nibble;
        input [7:0] c;
        begin
            if (c >= "0" && c <= "9")      hex_nibble = c - "0";
            else if (c >= "a" && c <= "f") hex_nibble = c - "a" + 8'd10;
            else if (c >= "A" && c <= "F") hex_nibble = c - "A" + 8'd10;
            else                           hex_nibble = 4'd0;
        end
    endfunction

    function [15:0] hex16;
        input [31:0] s;
        begin
            hex16 = {hex_nibble(s[31:24]), hex_nibble(s[23:16]),
                     hex_nibble(s[15:8]),  hex_nibble(s[7:0])};
        end
    endfunction

    localparam integer DEPTH = MEMORY_SIZE / WRITE_DATA_WIDTH_A;
    // Storage clamped to 2**SAW words, indexed by the low address bits, to keep
    // the proof small. DEPTH still matters: writes at addra >= DEPTH are dropped.
    localparam integer SAW   = (ADDR_WIDTH_A < 3) ? ADDR_WIDTH_A : 3;
    localparam [READ_DATA_WIDTH_B-1:0] RST_VAL = hex16(READ_RESET_VALUE_B);
    localparam COMMON  = (CLOCKING_MODE == "common_clock");
    localparam RD_FIRST = (WRITE_MODE_B == "read_first");
    localparam WR_FIRST = (WRITE_MODE_B == "write_first");
    localparam NO_CHG   = !RD_FIRST && !WR_FIRST;

    reg [WRITE_DATA_WIDTH_A-1:0] mem [0:(1<<SAW)-1];
    reg [READ_DATA_WIDTH_B-1:0]  doutb_r;
    reg [READ_DATA_WIDTH_B-1:0]  doutb_r2;

    wire rd_clk    = COMMON ? clka : clkb;
    wire wr_now    = ena & wea[0];
    wire wr_in_rng = (addra < DEPTH);
    wire collision = wr_now & (addra == addrb);

    always @(posedge clka) begin
        if (wr_now && wr_in_rng)
            mem[addra[SAW-1:0]] <= dina;
    end

    always @(posedge rd_clk) begin
        if (rstb)
            doutb_r <= RST_VAL;
        else if (enb) begin
            if (WR_FIRST && collision)
                doutb_r <= dina;
            else if (!(NO_CHG && wr_now))
                doutb_r <= mem[addrb[SAW-1:0]];
        end
    end

    always @(posedge rd_clk) begin
        if (rstb)
            doutb_r2 <= RST_VAL;
        else if (regceb)
            doutb_r2 <= doutb_r;
    end

    assign doutb    = (READ_LATENCY_B >= 2) ? doutb_r2 : doutb_r;
    assign sbiterrb = 1'b0;
    assign dbiterrb = 1'b0;

endmodule
