# Batch use: vivado -mode batch -source scripts/vivado.tcl -tclargs <top>
# Top is stream_arbiter (default) or stream_selftest. Run the launcher from
# build/vivado/<top> so its journal/log also stay generated.
# This is an out-of-context implementation, not a board bitstream.
set root [file normalize [file join [file dirname [info script]] ..]]
set top stream_arbiter
if {$argc > 1} {error "Usage: vivado.tcl ?stream_arbiter|stream_selftest?"}
if {$argc == 1} {set top [lindex $argv 0]}
if {$top ni {stream_arbiter stream_selftest}} {error "Unsupported top: $top"}
set out_dir [file join $root build vivado $top]
file mkdir $out_dir
cd $out_dir
set part xc7z020clg400-2

create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_param general.maxThreads 4
read_verilog -sv [lsort [glob [file join $root rtl *.sv]]]
read_xdc [file join $root scripts clock.xdc]
synth_design -top $top -part $part -mode out_of_context
# The I suffix is an operating grade, not part of Vivado's part identifier.
# This setting describes power conditions; STA still uses the device's
# characterized timing corners, reported in timing_summary.rpt.
set_operating_conditions -grade industrial
report_operating_conditions -file operating_conditions.rpt
write_checkpoint -force post_synth.dcp
report_utilization -file utilization_synth.rpt
opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force routed.dcp
report_utilization -file utilization.rpt
report_route_status -file route_status.rpt
report_drc -file drc.rpt
set checks [check_timing -verbose -return_string]
set check_file [open check_timing.rpt w]
puts $check_file $checks
close $check_file
# Fail closed if report parsing changes, or any timing-coverage check fails.
set check_counts [dict create]
foreach {match category count} [regexp -all -inline \
        {checking ([a-z_]+) \(([0-9]+)\)} $checks] {
    dict set check_counts $category $count
}
if {[dict size $check_counts] < 12} {error "Unrecognized check_timing report"}
set coverage_errors 0
dict for {category count} $check_counts {incr coverage_errors $count}
report_timing_summary -delay_type min_max -max_paths 10 \
    -report_unconstrained -check_timing_verbose -file timing_summary.rpt
report_timing -delay_type max -max_paths 10 -file setup_paths.rpt
report_timing -delay_type min -max_paths 10 -file hold_paths.rpt

# Keep internal sequential timing separate from unplaced OOC boundaries.
# all_registers includes memory primitives, not just flip-flops.
set regs [all_registers]
report_timing -from $regs -to $regs -delay_type max -max_paths 10 \
    -file internal_setup_paths.rpt
report_timing -from $regs -to $regs -delay_type min -max_paths 10 \
    -file internal_hold_paths.rpt
set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1]
set internal_setup [get_timing_paths -from $regs -to $regs -delay_type max -max_paths 1]
set internal_hold [get_timing_paths -from $regs -to $regs -delay_type min -max_paths 1]
if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0 ||
    [llength $internal_setup] == 0 || [llength $internal_hold] == 0} {
    error "No timed setup/hold path; inspect timing_summary.rpt"
}
set wns [get_property SLACK [lindex $setup_paths 0]]
set whs [get_property SLACK [lindex $hold_paths 0]]
set internal_wns [get_property SLACK [lindex $internal_setup 0]]
set internal_whs [get_property SLACK [lindex $internal_hold 0]]
set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
set data_inputs [get_ports -filter {DIRECTION == IN && NAME != clk}]
set boundary_wns 1e9
set boundary_whs 1e9
foreach path [concat \
        [get_timing_paths -from $data_inputs -delay_type max -max_paths 1] \
        [get_timing_paths -to [all_outputs] -delay_type max -max_paths 1]] {
    set boundary_wns [expr {min($boundary_wns, [get_property SLACK $path])}]
}
foreach path [concat \
        [get_timing_paths -from $data_inputs -delay_type min -max_paths 1] \
        [get_timing_paths -to [all_outputs] -delay_type min -max_paths 1]] {
    set boundary_whs [expr {min($boundary_whs, [get_property SLACK $path])}]
}
if {$boundary_wns == 1e9 || $boundary_whs == 1e9} {
    error "No boundary timing paths found"
}
set boundary_status MODELED_MET
if {$boundary_wns < 0 || $boundary_whs < 0} {set boundary_status MODELED_FAIL}
set summary [open result.txt w]
puts $summary "Vivado: [version -short]"
puts $summary "Top: $top"
puts $summary "Part: $part (user device XC7Z020-2CLG400I)"
puts $summary "Scope: out-of-context routed design, no board pins or bitstream"
puts $summary "Clock: 100 MHz; interface max/min: 2.0/0.2 ns"
puts $summary "All-path setup WNS: $wns ns"
puts $summary "All-path hold WHS: $whs ns"
puts $summary "Internal sequential setup WNS: $internal_wns ns"
puts $summary "Internal sequential hold WHS: $internal_whs ns"
puts $summary "Boundary setup WNS: $boundary_wns ns"
puts $summary "Boundary hold WHS: $boundary_whs ns"
puts $summary "Sequential cells analyzed: [llength $regs]"
puts $summary "Timing coverage issues: $coverage_errors"
puts $summary "DRC errors: [llength $drc_errors]"
puts $summary "Internal status: [expr {$internal_wns >= 0 && $internal_whs >= 0 ? {PASS} : {FAIL}}]"
puts $summary "Boundary status: $boundary_status (no physical OOC port locations)"
puts $summary "Clock/boundary insertion is an OOC estimate; full integration signoff required"
close $summary
if {$internal_wns < 0 || $internal_whs < 0 || $coverage_errors != 0 ||
    [llength $drc_errors] != 0} {
    error "OOC internal timing/coverage/DRC failed; inspect generated reports"
}
puts "OOC_INTERNAL_PASS boundary_status=$boundary_status part=$part top=$top"
if {$boundary_status eq "MODELED_FAIL"} {
    error "OOC boundary timing failed; full integration timing is not closed"
}
# Windows batch launchers can lose the Vivado process exit status. The Python
# entry requires this completion marker as well as a successful process exit.
set summary [open result.txt a]
puts $summary "Implementation status: PASS"
close $summary
exit 0
