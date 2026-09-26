# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# program_zcu106.tcl - Program the ZCU106 PL via Vivado Hardware Manager
# Usage: vivado -mode batch -source fpga/zcu106/scripts/program_zcu106.tcl
# Run from the repository root directory.
# =============================================================================

set bitfile build_zcu106/zcu106_top.bit

if {![file exists $bitfile]} {
    puts "ERROR: Bitstream not found: $bitfile"
    puts "Run build_zcu106.tcl first."
    exit 1
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

# The ZCU106 JTAG chain also has the ARM DAP; pick the FPGA by name.
set device [lindex [get_hw_devices -filter {NAME =~ xczu*}] 0]
if {$device eq ""} {
    puts "ERROR: no xczu* device found on the JTAG chain: [get_hw_devices]"
    exit 1
}
current_hw_device $device
set_property PROGRAM.FILE $bitfile $device

puts "Programming $device with $bitfile ..."
program_hw_devices $device

puts "Programming complete."
close_hw_target
disconnect_hw_server
close_hw_manager
