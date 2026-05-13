# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# build_arty.tcl - Vivado non-project mode build for emacZero on Arty A7-100T
# Usage: vivado -mode batch -source fpga/arty_a7/scripts/build_arty.tcl
# Run from the repository root directory.
# =============================================================================

set part xc7a100tcsg324-1
set top arty_a7_top
set outdir build_arty
set mac_filelist rtl/eth_mac_sys.f
set l3_filelist rtl/eth_mac_sys_l3.f

proc read_verilog_filelist {path} {
    set fh [open $path r]
    set files [list]
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string match "#*" $line]} {
            continue
        }
        lappend files $line
    }
    close $fh
    if {[llength $files] > 0} {
        read_verilog $files
    }
}

# Source files (relative to repo root)
set rtl_files [list \
    fpga/arty_a7/rtl/clk_gen.v \
    fpga/arty_a7/rtl/uart_tx.v \
    fpga/arty_a7/rtl/test_sequencer.v \
    fpga/arty_a7/rtl/arp_responder.v \
    fpga/arty_a7/rtl/arty_tx_arbiter.v \
    fpga/arty_a7/rtl/arty_a7_top.v \
]

set xdc_file fpga/arty_a7/constraints/arty_a7.xdc

file mkdir $outdir

# axilite_regs.v `includes` rtl/version.vh (single source of truth).
set_property include_dirs [list rtl] [current_fileset]

# Read sources
read_verilog_filelist $mac_filelist
read_verilog_filelist $l3_filelist
read_verilog $rtl_files
read_xdc $xdc_file

# Set Verilog defines for synthesis
set_property verilog_define {SYNTHESIS=1 XILINX_7SERIES=1} [current_fileset]

# Synthesis
puts "============================================================"
puts "  Synthesizing $top for $part"
puts "============================================================"
synth_design -top $top -part $part -flatten_hierarchy rebuilt
write_checkpoint -force $outdir/post_synth.dcp
report_utilization -file $outdir/utilization_synth.rpt
report_utilization

# Implementation
puts "============================================================"
puts "  Running implementation"
puts "============================================================"
opt_design
place_design
route_design
write_checkpoint -force $outdir/post_route.dcp
report_utilization -file $outdir/utilization_route.rpt
report_timing_summary -file $outdir/timing.rpt

# Check timing
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "============================================================"
puts "  Worst Negative Slack (WNS): $wns ns"
puts "============================================================"
if {$wns < 0} {
    puts "WARNING: Timing violation detected!"
} else {
    puts "Timing met."
}

# Bitstream
write_bitstream -force $outdir/${top}.bit
puts "============================================================"
puts "  Bitstream: $outdir/${top}.bit"
puts "============================================================"
