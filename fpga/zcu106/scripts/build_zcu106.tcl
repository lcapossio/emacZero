# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# build_zcu106.tcl - Vivado non-project build for emacZero on the AMD ZCU106
# (1000BASE-X over SFP cage 0). The PCS/PMA IP is created from this script,
# so no generated IP files are kept in the repository.
# Usage: vivado -mode batch -source fpga/zcu106/scripts/build_zcu106.tcl
#            [-tclargs [si570|si5328] [lb]]
# si570 (default) / si5328 picks the GTH reference clock: the USER_MGT_SI570
# at 156.25 MHz, or the Si5328 programmed to 125 MHz.
# lb adds the SFP0 <-> SFP1 loopback tester (a second PCS/PMA on SFP1,
# sfp_lb_tester and an fcapz EIO); output goes to build_zcu106_lb/.
# Run from the repository root directory.
# =============================================================================

set part xczu7ev-ffvc1156-2-e
set top zcu106_top
set mac_filelist rtl/eth_mac_sys.f
set l3_filelist rtl/eth_mac_sys_l3.f

set refclk si570
set lb 0
foreach arg $argv {
    switch -- $arg {
        si570   { set refclk si570 }
        si5328  { set refclk si5328 }
        lb      { set lb 1 }
        default {
            puts "ERROR: unknown argument '$arg' (use si570, si5328, lb)"
            exit 1
        }
    }
}
if {$refclk eq "si570"} {
    set refclk_mhz 156.25; set refclk_si5328 0
} else {
    set refclk_mhz 125;    set refclk_si5328 1
}
set outdir [expr {$lb ? "build_zcu106_lb" : "build_zcu106"}]
puts "GTH reference clock: $refclk ($refclk_mhz MHz), SFP1 loopback: $lb"

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

file mkdir $outdir/ip
create_project -in_memory -part $part
set_property target_language Verilog [current_project]

# -----------------------------------------------------------------------------
# 1G/2.5G Ethernet PCS/PMA: 1000BASE-X, GTH, refclk per $refclk, shared logic in
# core, no MDIO (configuration_vector instead), 50 MHz independent clock.
# GT_Location is the SFP0 channel, GTHE4_CHANNEL_X0Y10 (SFP1 is X0Y11).
# -----------------------------------------------------------------------------
create_ip -name gig_ethernet_pcs_pma -vendor xilinx.com -library ip \
    -module_name pcs_pma_1000basex -dir $outdir/ip -force
set_property -dict [list \
    CONFIG.Standard             1000BASEX \
    CONFIG.Physical_Interface   Transceiver \
    CONFIG.GT_Type              GTH \
    CONFIG.GT_Location          X0Y10 \
    CONFIG.RefClkRate           $refclk_mhz \
    CONFIG.DrpClkRate           50.0 \
    CONFIG.SupportLevel         Include_Shared_Logic_in_Core \
    CONFIG.Management_Interface false \
    CONFIG.Auto_Negotiation     true \
] [get_ips pcs_pma_1000basex]
generate_target all [get_ips pcs_pma_1000basex]
synth_ip [get_ips pcs_pma_1000basex]

# Loopback build: a second core for SFP1 without shared logic; it takes the
# reference clock, user clocks and resets from pcs_pma_1000basex.
if {$lb} {
    create_ip -name gig_ethernet_pcs_pma -vendor xilinx.com -library ip \
        -module_name pcs_pma_1000basex_ns -dir $outdir/ip -force
    set_property -dict [list \
        CONFIG.Standard             1000BASEX \
        CONFIG.Physical_Interface   Transceiver \
        CONFIG.GT_Type              GTH \
        CONFIG.GT_Location          X0Y11 \
        CONFIG.RefClkRate           $refclk_mhz \
        CONFIG.DrpClkRate           50.0 \
        CONFIG.SupportLevel         Include_Shared_Logic_in_Example_Design \
        CONFIG.Management_Interface false \
        CONFIG.Auto_Negotiation     true \
    ] [get_ips pcs_pma_1000basex_ns]
    generate_target all [get_ips pcs_pma_1000basex_ns]
    synth_ip [get_ips pcs_pma_1000basex_ns]
}

# -----------------------------------------------------------------------------
# Sources
# -----------------------------------------------------------------------------
set_property include_dirs [list rtl fpga/zcu106/rtl fcapz/rtl] [current_fileset]
read_verilog_filelist $mac_filelist
read_verilog_filelist $l3_filelist
read_verilog [list \
    fpga/arty_a7/rtl/arp_responder.v \
    fpga/arty_a7/rtl/arty_tx_arbiter.v \
    fpga/zcu106/rtl/i2c_init.v \
    fpga/zcu106/rtl/zcu106_eth_demo.v \
    fpga/zcu106/rtl/zcu106_top.v \
]
if {$lb} {
    read_verilog [list \
        fpga/zcu106/rtl/sfp_lb_tester.v \
        fcapz/rtl/jtag_tap/jtag_tap_xilinx7.v \
        fcapz/rtl/jtag_reg_iface.v \
        fcapz/rtl/fcapz_eio.v \
        fcapz/rtl/fcapz_eio_xilinx7.v \
        fcapz/rtl/fcapz_eio_xilinxus.v \
    ]
}
# The refclk file creates sfp_refclk, which zcu106.xdc's clock groups use,
# so it has to be read first.
read_xdc fpga/zcu106/constraints/refclk_$refclk.xdc
read_xdc fpga/zcu106/constraints/zcu106.xdc
set defines {SYNTHESIS=1}
if {$lb} {
    read_xdc fpga/zcu106/constraints/sfp1_lb.xdc
    lappend defines ZCU106_SFP1_LB=1
}
set_property verilog_define $defines [current_fileset]

# -----------------------------------------------------------------------------
# Synthesis and implementation
# -----------------------------------------------------------------------------
puts "============================================================"
puts "  Synthesizing $top for $part"
puts "============================================================"
synth_design -top $top -part $part -flatten_hierarchy rebuilt \
    -generic REFCLK_SI5328=$refclk_si5328
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
