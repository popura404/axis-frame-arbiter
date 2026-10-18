# Matched single-clock aggregation boundaries, not a complete RFNoC system.
# The Python runner snapshots the repository's context, clock and report
# scripts under build/rfnoc/impl/reference and records their file hashes.
set root [file normalize [file join [file dirname [info script]] ..]]
if {$argc != 1 || [lindex $argv 0] ni {0 1 2}} {
    error "Usage: rfnoc_impl.tcl external(0|1|2)"
}
set external [lindex $argv 0]
set reference [file join $root build rfnoc impl reference]
foreach name {registered_context.tcl clock.xdc report_reference.tcl} {
    if {![file isfile [file join $reference $name]]} {
        error "Missing reference/$name; prepare with the RFNoC comparison runner"
    }
}
set top rfnoc_arbiter
set keep_enable 0
set configuration p4-w32-d16-packet-m6-keep0-external${external}
set out_dir [file join $root build rfnoc impl $configuration]
file mkdir $out_dir
cd $out_dir
file delete -force result.txt
set part xc7z020clg400-2
create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_param general.maxThreads 4
read_verilog -sv [lsort [glob [file join $root rtl *.sv]]]
read_verilog -sv [file join $root sim rfnoc_arbiter.sv]
if {$external} {
    read_verilog -sv [file join $root sim axis_external.sv]
    foreach name {axis_fifo.v axis_arb_mux.v arbiter.v priority_encoder.v} {
        read_verilog [file join $root build vendor verilog-axis rtl $name]
    }
}
read_xdc [file join $reference clock.xdc]
synth_design -top $top -part $part -mode out_of_context -generic EXTERNAL=$external
if {[llength [get_ports -quiet clk]] != 1} {error "Expected exactly one aggregation clock"}
set_operating_conditions -grade industrial
report_operating_conditions -file operating_conditions.rpt
write_checkpoint -force post_synth.dcp
report_utilization -file utilization_core_synth.rpt
report_utilization -hierarchical -file utilization_core_hierarchy.rpt
source [file join $reference registered_context.tcl]
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force routed.dcp
source [file join $reference report_reference.tcl]
