# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# program_zcu106.tcl - Program the ZCU106 PL via Vivado Hardware Manager
# Usage: vivado -mode batch -source fpga/zcu106/scripts/program_zcu106.tcl
#            [-tclargs <bitfile>]
# Default bitfile: build_zcu106/zcu106_top.bit (the loopback build is
# build_zcu106_lb/zcu106_top.bit). Run from the repository root directory.
# =============================================================================

set bitfile [expr {[llength $argv] > 0 ? [lindex $argv 0] : "build_zcu106/zcu106_top.bit"}]

if {![file exists $bitfile]} {
    puts "ERROR: Bitstream not found: $bitfile"
    puts "Run build_zcu106.tcl first."
    exit 1
}

open_hw_manager
connect_hw_server -allow_non_jtag

# Other boards may share the hw_server, so search every JTAG target for the
# ZCU106's xczu7ev. Its chain also has the ARM DAP; pick the FPGA by name.
set device ""
foreach target [get_hw_targets] {
    if {[catch {open_hw_target $target}]} {
        continue
    }
    set device [lindex [get_hw_devices -quiet -filter {NAME =~ xczu7*}] 0]
    if {$device ne ""} {
        puts "Using $device on $target"
        break
    }
    close_hw_target $target
}
if {$device eq ""} {
    puts "ERROR: no xczu7* device found on any JTAG target: [get_hw_targets]"
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
