# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# elab_check.tcl - Vivado RTL elaboration gate for the regression
# Usage: vivado -mode batch -source fpga/arty_a7/scripts/elab_check.tcl
# Run from the repository root directory.
#
# Elaborates the Arty top (which pulls in the whole MAC and the optional L3
# helpers) WITHOUT synthesizing, placing or routing, so the regression catches
# elaboration-time errors in about a minute instead of at bitstream time.
#
# This exists because neither linter covers that class of defect. An
# out-of-range part-select - tx_fifo_level slicing fifo_count[12:0] from a
# 12-bit counter - passed `iverilog -Wall` and Verilator for two months and was
# only caught when Vivado refused to elaborate it, by which point no Arty
# bitstream could be built at all. Icarus has no general width-mismatch class
# and Verilator's WIDTH warnings are waived in this project's lint args, so
# only a real elaborator closes the gap.
# =============================================================================

set part xc7a100tcsg324-1
set top arty_a7_top
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

set rtl_files [list \
    fpga/arty_a7/rtl/clk_gen.v \
    fpga/arty_a7/rtl/uart_tx.v \
    fpga/arty_a7/rtl/test_sequencer.v \
    fpga/arty_a7/rtl/arp_responder.v \
    fpga/arty_a7/rtl/arty_tx_arbiter.v \
    fpga/arty_a7/rtl/arty_a7_top.v \
]

# axilite_regs.v `includes` rtl/version.vh (single source of truth).
set_property include_dirs [list rtl] [current_fileset]

read_verilog_filelist $mac_filelist
read_verilog_filelist $l3_filelist
read_verilog $rtl_files

set_property verilog_define {SYNTHESIS=1 XILINX_7SERIES=1} [current_fileset]

puts "============================================================"
puts "  Elaborating $top for $part (RTL only)"
puts "============================================================"

# -rtl stops after elaboration: no synthesis, no checkpoints, no bitstream.
if {[catch {synth_design -rtl -name elab_check -top $top -part $part} err]} {
    puts "ERROR: RTL elaboration failed: $err"
    exit 1
}

puts "RTL elaboration clean"
exit 0
