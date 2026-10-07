# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
# =============================================================================
# rgmii_impl_check.tcl - implement rgmii_if alone (synth, opt, place, route)
# and check what simulation and elaboration cannot:
#   - 6 DDR output and 5 DDR input cells, whatever RGMII_SPEEDS is;
#   - each DDR output cell drives one output buffer and nothing else (a LUT
#     there is rejected: REQP-1884 on 7-series, Place 30-1902 on UltraScale+);
#   - place and route complete;
#   - the internal register-to-register paths meet setup and hold.
# The I/O is left unconstrained and unplaced: only the cell legality and the
# internal timing are checked.
#
# Usage (run by build_and_test.py --impl):
#   vivado -mode batch -source fpga/scripts/rgmii_impl_check.tcl \
#       -tclargs <repo root> <RGMII_SPEEDS> <part> <XILINX_7SERIES|XILINX_ULTRASCALE_PLUS>
# Prints one "RGMII_IMPL OK|FAIL <define> <speeds> ..." line; exits 1 on FAIL.
# =============================================================================

set root   [lindex $argv 0]
set speeds [lindex $argv 1]
set part   [lindex $argv 2]
set def    [lindex $argv 3]
set tag    "$def $speeds"

proc done {ok msg} {
    global tag
    if {$ok} {
        puts "RGMII_IMPL OK $tag $msg"
        exit 0
    }
    puts "RGMII_IMPL FAIL $tag $msg"
    exit 1
}

read_verilog [list $root/rtl/rgmii_if.v $root/rtl/ddr_input.v $root/rtl/ddr_output.v]
if {[catch {synth_design -top rgmii_if -part $part -generic RGMII_SPEEDS=\"$speeds\" \
        -verilog_define $def=1 -verilog_define SYNTHESIS=1} msg]} {
    done 0 "synth_design: $msg"
}

create_clock -name clk_125   -period 8.0 [get_ports clk_125]
create_clock -name rgmii_rxc -period 8.0 [get_ports rgmii_rxc]
# clk_125_90 has no load for "10_100".
if {[llength [get_nets -quiet -of [get_ports clk_125_90]]]} {
    create_clock -name clk_125_90 -period 8.0 -waveform {2.0 6.0} [get_ports clk_125_90]
    set_clock_groups -asynchronous -group [get_clocks {clk_125 clk_125_90}] -group rgmii_rxc
} else {
    set_clock_groups -asynchronous -group clk_125 -group rgmii_rxc
}
set_property IOSTANDARD LVCMOS18 [get_ports *]
set_property SEVERITY Warning [get_drc_checks UCIO-1]
set_property SEVERITY Warning [get_drc_checks NSTD-1]

foreach step {opt_design place_design route_design} {
    if {[catch {$step} msg]} { done 0 "$step: $msg" }
}

# opt_design maps ODDRE1 to OSERDESE3 and IDDRE1 stays IDDRE1.
set outs [get_cells -hier -quiet -filter {REF_NAME == ODDR || REF_NAME == OSERDESE3}]
set ins  [get_cells -hier -quiet -filter {REF_NAME == IDDR || REF_NAME == IDDRE1}]
if {[llength $outs] != 6 || [llength $ins] != 5} {
    done 0 "expected 6 DDR output and 5 DDR input cells, found [llength $outs] and [llength $ins]"
}
foreach c $outs {
    set q     [get_pins -of $c -filter {REF_PIN_NAME == Q || REF_PIN_NAME == OQ}]
    set loads [get_pins -leaf -quiet -of [get_nets -of $q] -filter {DIRECTION == IN}]
    set refs  [get_property REF_NAME [get_cells -quiet -of $loads]]
    if {[llength $loads] != 1 || ![string match OBUF* $refs]} {
        done 0 "$c drives '$refs', not one output buffer"
    }
}

set s [get_timing_paths -max_paths 1 -setup -from [all_registers] -to [all_registers]]
set h [get_timing_paths -max_paths 1 -hold  -from [all_registers] -to [all_registers]]
set wns [get_property SLACK $s]
set whs [get_property SLACK $h]
set info "WNS $wns ns WHS $whs ns, worst [get_property STARTPOINT_CLOCK $s] -> [get_property ENDPOINT_CLOCK $s] at [get_property ENDPOINT_PIN $s]"
if {$wns eq "" || $whs eq "" || $wns < 0 || $whs < 0} {
    done 0 $info
}
done 1 $info
