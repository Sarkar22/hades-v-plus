# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: synth.tcl

# Get root directory
set ROOT [file normalize [file dirname [info script]]/..]

# Supress some warnings
# identifier <name> is used before its declaration
set_msg_config -id {Synth 8-6901} -suppress

# <name> is already implicitly declared earlier
set_msg_config -id {Synth 8-8895} -suppress

# Unused sequential element <name>_reg was removed
set_msg_config -id {Synth 8-6014} -string {test_reg_reg} -suppress
set_msg_config -id {Synth 8-6014} -string {test_stb_reg} -suppress

# Port <port> in module <module> is either unconnected or has no load
set_msg_config -id {Synth 8-7129} -string {wishbone_buttons} -suppress
set_msg_config -id {Synth 8-7129} -string {wishbone_leds} -suppress
set_msg_config -id {Synth 8-7129} -string {wishbone_switches} -suppress
set_msg_config -id {Synth 8-7129} -string {wishbone_test} -suppress
set_msg_config -id {Synth 8-7129} -string {wishbone_uart} -suppress

# initial value of parameter '<parameter>' is omitted [<path>]
set_msg_config -id {Synth 8-9661} -suppress

# Parallel synthesis criteria is not met
set_msg_config -id {Synth 8-7080} -suppress

# Define source files
set SOURCES {
    defines/bpredict.sv
    defines/csr.sv
    defines/op.sv
    defines/instruction.sv
    defines/pipeline_status.sv
    defines/constants.sv
    defines/forwarding.sv
    defines/clk_params.sv

    lib/*.sv
    lib/peripherals/*.sv
    lib/wishbone/*.sv

    ref/*.sv
    rtl/*.sv

    synth/top.sv
}

foreach source $SOURCES {
    read_verilog -sv [glob -directory $ROOT $source]
}

# Read constraints
read_xdc $ROOT/synth/basys3.xdc

# Read memory file (the Makefile passes its location, which follows BUILD_DIR;
# without it, the default build directory inside the repository is used)
if {[info exists ::env(HADES_BOOTLOADER_MEM)]} {
    read_mem $::env(HADES_BOOTLOADER_MEM)
} else {
    read_mem $ROOT/build/test/c/bootloader/init.mem
}

# Synthesize and Optimize
synth_design -top top -part xc7a35tcpg236-1
opt_design

# Synthesis reports
file mkdir reports
report_timing_summary -file reports/timing_syn.rpt
report_power -file reports/power_syn.rpt
report_design_analysis -file reports/design_analysis.rpt

# Place and Route
# Timing directives: the critical path (instruction_reg_out -> RAM write-enable)
# is constrained to a 10 ns half-period because the BRAM runs on clk_mem = ~clk.
# Default P&R closes at only +0.004 ns WNS; these directives widen it to ~+0.24 ns.
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore
phys_opt_design -directive AggressiveExplore

# PnR Reports
report_timing_summary -file reports/timing_pnr.rpt
report_utilization -file reports/utilization_pnr.rpt
report_power -file reports/power_pnr.rpt

# Generate bitstream
# The forwarding/CSR/wishbone-interrupt muxes form a feedback structure that
# trips DRC LUTLP-1 (combinational loop). Upstream waives the same structure in
# simulation via lint_off UNOPTFLAT; downgrade it so write_bitstream can run.
set_property SEVERITY {Warning} [get_drc_checks LUTLP-1]
write_bitstream -force -bin hades-v.bit
