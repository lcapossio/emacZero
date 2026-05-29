// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// xpm_memory_sdpram_model.v - Simulation model for Xilinx xpm_memory_sdpram
//
// Minimal behavioral model covering the simple-dual-port, common-clock,
// READ_LATENCY_B=1 configuration that mii_if.v uses for the RX frame buffer.
// Mirrors the generic inferred block-RAM path (1-cycle registered read,
// independent write/read ports, write port A / read port B) so XILINX_7SERIES
// simulation builds behave like the non-Xilinx inferred build.
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module xpm_memory_sdpram #(
    parameter integer ADDR_WIDTH_A            = 6,
    parameter integer ADDR_WIDTH_B            = 6,
    parameter integer AUTO_SLEEP_TIME         = 0,
    parameter integer BYTE_WRITE_WIDTH_A      = 32,
    parameter integer CASCADE_HEIGHT          = 0,
    parameter         CLOCKING_MODE           = "common_clock",
    parameter         ECC_MODE                = "no_ecc",
    parameter         MEMORY_INIT_FILE        = "none",
    parameter         MEMORY_INIT_PARAM       = "0",
    parameter         MEMORY_OPTIMIZATION     = "true",
    parameter         MEMORY_PRIMITIVE        = "auto",
    parameter integer MEMORY_SIZE             = 2048,
    parameter integer MESSAGE_CONTROL         = 0,
    parameter integer READ_DATA_WIDTH_B       = 32,
    parameter integer READ_LATENCY_B          = 2,
    parameter         READ_RESET_VALUE_B      = "0",
    parameter         RST_MODE_A              = "SYNC",
    parameter         RST_MODE_B              = "SYNC",
    parameter integer USE_EMBEDDED_CONSTRAINT = 0,
    parameter integer USE_MEM_INIT            = 1,
    parameter         WAKEUP_TIME             = "disable_sleep",
    parameter integer WRITE_DATA_WIDTH_A      = 32,
    parameter         WRITE_MODE_B            = "no_change"
)(
    input  wire                                              sleep,
    input  wire                                              clka,
    input  wire                                              ena,
    input  wire [WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-1:0]  wea,
    input  wire [ADDR_WIDTH_A-1:0]                           addra,
    input  wire [WRITE_DATA_WIDTH_A-1:0]                     dina,
    input  wire                                              injectsbiterra,
    input  wire                                              injectdbiterra,
    input  wire                                              clkb,
    input  wire                                              rstb,
    input  wire                                              enb,
    input  wire                                              regceb,
    input  wire [ADDR_WIDTH_B-1:0]                           addrb,
    output wire [READ_DATA_WIDTH_B-1:0]                      doutb,
    output wire                                              sbiterrb,
    output wire                                              dbiterrb
);
    localparam integer DEPTH = MEMORY_SIZE / READ_DATA_WIDTH_B;

    reg [READ_DATA_WIDTH_B-1:0] mem [0:DEPTH-1];
    reg [READ_DATA_WIDTH_B-1:0] doutb_r;

    assign doutb    = doutb_r;
    assign sbiterrb = 1'b0;
    assign dbiterrb = 1'b0;

    // Write port A: whole-word write when enabled (wea covers the full word).
    always @(posedge clka) begin
        if (ena && (wea != 0))
            mem[addra] <= dina;
    end

    // Read port B: 1-cycle registered read (READ_LATENCY_B == 1).
    always @(posedge clkb) begin
        if (enb)
            doutb_r <= mem[addrb];
    end
endmodule
