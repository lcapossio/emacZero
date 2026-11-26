# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# build_zcu106_10g.tcl - Vivado non-project build of the 10GBASE-R bring-up
# design (zcu106_10g_top) for the AMD ZCU106, SFP cage 0. No IP is generated:
# the GTH transceiver primitives are instantiated directly.
# Usage: vivado -mode batch -source fpga/zcu106/scripts/build_zcu106_10g.tcl
# Output goes to build_zcu106_10g/. Run from the repository root directory.
# =============================================================================

set part   xczu7ev-ffvc1156-2-e
set top    zcu106_10g_top
set outdir build_zcu106_10g

file mkdir $outdir
create_project -in_memory -part $part
set_property target_language Verilog [current_project]

# -----------------------------------------------------------------------------
# Sources
# -----------------------------------------------------------------------------
set_property include_dirs [list rtl fpga/zcu106/rtl fcapz/rtl] [current_fileset]
read_verilog [list \
    rtl/pcs10gbr_enc.v \
    rtl/pcs10gbr_dec.v \
    rtl/pcs10gbr_scrambler.v \
    rtl/pcs10gbr_gearbox_tx.v \
    rtl/pcs10gbr_gearbox_rx.v \
    rtl/pcs10gbr_block_lock.v \
    rtl/pcs10gbr_ber_mon.v \
    rtl/pcs10gbr.v \
    fpga/zcu106/rtl/gthe4_common_10g.v \
    fpga/zcu106/rtl/gthe4_channel_10g.v \
    fpga/zcu106/rtl/gt10g_reset.v \
    fpga/zcu106/rtl/xgmii_test_gen.v \
    fpga/zcu106/rtl/xgmii_test_chk.v \
    fpga/zcu106/rtl/zcu106_10g_top.v \
    fcapz/rtl/jtag_tap/jtag_tap_xilinx7.v \
    fcapz/rtl/jtag_reg_iface.v \
    fcapz/rtl/fcapz_eio.v \
    fcapz/rtl/fcapz_eio_xilinx7.v \
    fcapz/rtl/fcapz_eio_xilinxus.v \
]
read_xdc fpga/zcu106/constraints/zcu106_10g.xdc
set_property verilog_define {SYNTHESIS=1 XILINX_ULTRASCALE_PLUS=1} [current_fileset]

# -----------------------------------------------------------------------------
# Synthesis and implementation
# -----------------------------------------------------------------------------
puts "============================================================"
puts "  Synthesizing $top for $part"
puts "============================================================"
synth_design -top $top -part $part -flatten_hierarchy rebuilt
write_checkpoint -force $outdir/post_synth.dcp
report_utilization -file $outdir/utilization_synth.rpt

puts "============================================================"
puts "  Running implementation"
puts "============================================================"
opt_design
place_design
route_design
write_checkpoint -force $outdir/post_route.dcp
report_utilization -file $outdir/utilization_route.rpt
report_timing_summary -file $outdir/timing.rpt
report_clocks -file $outdir/clocks.rpt
report_clock_interaction -file $outdir/clock_interaction.rpt
report_methodology -file $outdir/methodology.rpt
report_cdc -details -file $outdir/cdc.rpt
report_drc -file $outdir/drc.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -hold]]
puts "============================================================"
puts "  WNS = $wns ns, WHS = $whs ns"
puts "============================================================"
if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met"
    exit 1
}

write_bitstream -force $outdir/$top.bit
puts "Bitstream: $outdir/$top.bit"
