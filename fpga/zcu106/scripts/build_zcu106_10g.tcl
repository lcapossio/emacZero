# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# build_zcu106_10g.tcl - Vivado non-project build of the 10GBASE-R design
# (zcu106_10g_top, with the eth_mac_sys_10g test path) for the AMD ZCU106, SFP
# cages 0 and 1. No IP is generated: the GTH transceiver primitives are
# instantiated directly.
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
    rtl/crc32_d64.v \
    rtl/eth_mac_10g_tx.v \
    rtl/eth_mac_10g_rx.v \
    rtl/eth_rs_10g.v \
    rtl/eth_pause_10g.v \
    rtl/async_fifo.v \
    rtl/axis_async_frame_fifo.v \
    rtl/cdc_event_count.v \
    rtl/eth_mac_sys_10g.v \
    fpga/zcu106/rtl/gthe4_common_10g.v \
    fpga/zcu106/rtl/gthe4_channel_10g.v \
    fpga/zcu106/rtl/gt10g_reset.v \
    fpga/zcu106/rtl/xgmii_test_gen.v \
    fpga/zcu106/rtl/xgmii_test_chk.v \
    fpga/zcu106/rtl/axis_test_gen64.v \
    fpga/zcu106/rtl/axis_test_chk64.v \
    fpga/zcu106/rtl/axil_cmd_master.v \
    rtl/net/net_rx.v \
    rtl/net/icmp_echo.v \
    rtl/net/udp_echo.v \
    fpga/arty_a7/rtl/arp_responder.v \
    fpga/arty_a7/rtl/arty_tx_arbiter.v \
    fpga/zcu106/rtl/net_service64.v \
    fpga/zcu106/rtl/zcu106_10g_lane.v \
    fpga/zcu106/rtl/zcu106_10g_port.v \
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

# The reference clock buffer must sit on the MGTREFCLK1 buffer of Quad 226
# (the U10/U9 pins carry the Si570 clock; the placer can move the buffer to
# the unconnected MGTREFCLK0 one while still reporting the ports on U10/U9).
# Also print where the clock enters the COMMON, for the record.
set ib [get_cells -hierarchical -filter {REF_NAME == IBUFDS_GTE4}]
if {[get_property LOC $ib] ne "GTHE4_COMMON_X0Y3" ||
    [get_property BEL $ib] ne "GTHE4_COMMON.IBUFDS1_GTHE4"} {
    puts "ERROR: reference clock buffer on [get_property LOC $ib] [get_property BEL $ib]"
    exit 1
}
set cm [get_cells -hierarchical -filter {REF_NAME == GTHE4_COMMON}]
foreach p [get_pins -of $cm -filter {DIRECTION == IN && REF_PIN_NAME =~ GT*REFCLK*}] {
    if {[get_property TYPE [get_nets -of $p]] eq "SIGNAL"} {
        puts "Reference clock: [get_property REF_PIN_NAME $p] -> BEL pin [get_bel_pins -quiet -of $p]"
    }
}
puts "QPLL0REFCLKSEL: [get_property TYPE [get_nets -of [get_pins $cm/QPLL0REFCLKSEL[2]]]] [get_property TYPE [get_nets -of [get_pins $cm/QPLL0REFCLKSEL[1]]]] [get_property TYPE [get_nets -of [get_pins $cm/QPLL0REFCLKSEL[0]]]]"
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
