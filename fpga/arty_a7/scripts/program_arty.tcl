# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# program_arty.tcl - Program Arty A7 via Vivado Hardware Manager
# Usage: vivado -mode batch -source fpga/arty_a7/scripts/program_arty.tcl
# Run from the repository root directory.
# =============================================================================

set bitfile build_arty/arty_a7_top.bit

if {![file exists $bitfile]} {
    puts "ERROR: Bitstream not found: $bitfile"
    puts "Run build_arty.tcl first."
    exit 1
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set device [lindex [get_hw_devices] 0]
current_hw_device $device
set_property PROGRAM.FILE $bitfile $device

puts "Programming $device with $bitfile ..."
program_hw_devices $device

puts "Programming complete."
close_hw_target
disconnect_hw_server
close_hw_manager
