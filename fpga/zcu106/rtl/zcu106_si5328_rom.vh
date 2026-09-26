// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// zcu106_si5328_rom.vh - I2C writes that set the ZCU106 Si5328 (U20) to
// 125 MHz for the SFP GTH reference clock (Quad 225 MGTREFCLK1, W10/W9).
// UG1244 routes CKOUT1 there, but some board notes name CKOUT2, so both
// outputs are enabled and both are set to 125 MHz.
// Included by i2c_init.v. Only used when zcu106_top has REFCLK_SI5328 = 1.
//
// Bus: PL IIC1 -> TCA9548A U34 at 0x74, channel 4 (control byte 0x10).
// Si5328 7-bit address: the ZCU106 user guide (UG1244) lists 0x68, while the
// rev 1.0 schematic (A0 pulled up) and the Linux zcu106 device tree use 0x69.
// i2c_init alternates `alt` on every retry, so the list is tried at 0x69
// first and at 0x68 on the next pass; the part that ACKs gets programmed.
//
// Free-run from the 114.285 MHz XA/XB crystal (routed to CKIN2 by FREE_RUN):
//   N31 = N32 = 4565  -> f3   = 114.285 MHz / 4565    = 25.035 kHz
//   N2  = 10 x 19972  -> fosc = f3 x 199720           = 5.000 GHz
//   N1  = 10 x 4      -> CKOUT1 = CKOUT2 = fosc / 40  = 125.000 MHz
// These are the divider values ARTIQ uses for 125 MHz from the same crystal
// (m-labs/artiq, rtio_clocking.rs, "Int_125"), with BWSEL = 4. Register
// fields per the Si5328 datasheet. Not yet verified on hardware.
//
// Entry format: {last[1:0], b0, b1, b2}; b0 is the address+W byte and `last`
// is the index of the final byte (1 = 2-byte write, 2 = 3-byte write).
// =============================================================================

localparam ROM_LEN = 28;

function [25:0] rom_entry;
    input [15:0] i;
    input        alt;               // 0: Si5328 at 0x69, 1: at 0x68
    reg   [7:0]  si;
    begin
        si = alt ? 8'hD0 : 8'hD2;   // 0x68 / 0x69, write
        case (i)
        // TCA9548A U34 (0x74): enable channel 4 only
        16'd0:  rom_entry = {2'd1, 8'hE8, 8'h10, 8'h00};
        // Si5328 {register, value}
        16'd1:  rom_entry = {2'd2, si, 8'd0,   8'h54};  // FREE_RUN=1
        16'd2:  rom_entry = {2'd2, si, 8'd1,   8'hE4};  // CK_PRIOR default
        16'd3:  rom_entry = {2'd2, si, 8'd2,   8'h42};  // BWSEL_REG=4
        16'd4:  rom_entry = {2'd2, si, 8'd3,   8'h55};  // CKSEL_REG=CKIN2, SQ_ICAL=1
        16'd5:  rom_entry = {2'd2, si, 8'd4,   8'h12};  // AUTOSEL_REG=manual
        16'd6:  rom_entry = {2'd2, si, 8'd6,   8'h3F};  // SFOUT1/2 = LVDS
        16'd7:  rom_entry = {2'd2, si, 8'd10,  8'h00};  // CKOUT1 and CKOUT2 enabled
        16'd8:  rom_entry = {2'd2, si, 8'd11,  8'h40};
        16'd9:  rom_entry = {2'd2, si, 8'd21,  8'hFE};  // CKSEL_PIN=0 (use CKSEL_REG)
        16'd10: rom_entry = {2'd2, si, 8'd25,  8'hC0};  // N1_HS=10
        16'd11: rom_entry = {2'd2, si, 8'd31,  8'h00};  // NC1_LS=4 (value-1 = 3)
        16'd12: rom_entry = {2'd2, si, 8'd32,  8'h00};
        16'd13: rom_entry = {2'd2, si, 8'd33,  8'h03};
        16'd14: rom_entry = {2'd2, si, 8'd34,  8'h00};  // NC2_LS=4
        16'd15: rom_entry = {2'd2, si, 8'd35,  8'h00};
        16'd16: rom_entry = {2'd2, si, 8'd36,  8'h03};
        16'd17: rom_entry = {2'd2, si, 8'd40,  8'hC0};  // N2_HS=10, N2_LS=19972 (0x4E03+1)
        16'd18: rom_entry = {2'd2, si, 8'd41,  8'h4E};
        16'd19: rom_entry = {2'd2, si, 8'd42,  8'h03};
        16'd20: rom_entry = {2'd2, si, 8'd43,  8'h00};  // N31=4565 (0x11D4+1)
        16'd21: rom_entry = {2'd2, si, 8'd44,  8'h11};
        16'd22: rom_entry = {2'd2, si, 8'd45,  8'hD4};
        16'd23: rom_entry = {2'd2, si, 8'd46,  8'h00};  // N32=4565
        16'd24: rom_entry = {2'd2, si, 8'd47,  8'h11};
        16'd25: rom_entry = {2'd2, si, 8'd48,  8'hD4};
        16'd26: rom_entry = {2'd2, si, 8'd137, 8'h01};  // FASTLOCK=1
        default:rom_entry = {2'd2, si, 8'd136, 8'h40};  // ICAL: calibrate, last
        endcase
    end
endfunction
