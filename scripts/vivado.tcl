# Use scripts/build.py so launcher outputs stay in build/vivado/<top>/<context>.
# registered = physical same-clock reference integration, NOT a board bitstream.
# ports = original abstract OOC interface budget; diagnostic only without a parent.
set root [file normalize [file join [file dirname [info script]] ..]]
set top stream_arbiter
set context registered
if {$argc > 2} {error "Usage: vivado.tcl ?top? ?registered|ports?"}
if {$argc >= 1} {set top [lindex $argv 0]}
if {$argc == 2} {set context [lindex $argv 1]}
if {$top ni {stream_arbiter stream_selftest} || $context ni {registered ports}} {
    error "Unsupported top/context"
}
set out_dir [file join $root build vivado $top $context]
file mkdir $out_dir
cd $out_dir
file delete -force result.txt
set part xc7z020clg400-2
create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_param general.maxThreads 4
read_verilog -sv [lsort [glob [file join $root rtl *.sv]]]
read_xdc [file join $root scripts clock.xdc]
synth_design -top $top -part $part -mode out_of_context
# Industrial affects the power conditions, not arbitrary STA temperature tuning.
set_operating_conditions -grade industrial
report_operating_conditions -file operating_conditions.rpt
write_checkpoint -force post_synth.dcp
report_utilization -file utilization_core_synth.rpt
if {$context eq "registered"} {
    source [file join $root scripts registered_context.tcl]
}
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force routed.dcp
write_xdc -force effective.xdc
report_utilization -file utilization.rpt
report_route_status -file route_status.rpt
# DRC alone can miss partial OOC routes/antennas. Gate routing independently.
set fully_routed [report_route_status -boolean_check ROUTED_FULLY]
set route_errors [report_route_status -boolean_check ERRORS_IN_ROUTES]
report_drc -file drc.rpt
set drc_errors [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]

proc save_text {path content} {
    set f [open $path w]
    puts $f $content
    close $f
}
set checks [check_timing -verbose -return_string]
save_text check_timing.rpt $checks
set check_counts [dict create]
foreach {match category count} [regexp -all -inline \
        {checking ([a-z_]+) \(([0-9]+)\)} $checks] {
    dict set check_counts $category $count
}
if {[dict size $check_counts] < 12} {error "Unrecognized check_timing report"}
set coverage_errors 0
dict for {category count} $check_counts {incr coverage_errors $count}
set timing [report_timing_summary -delay_type min_max -max_paths 10 \
    -report_unconstrained -check_timing_verbose -return_string]
save_text timing_summary.rpt $timing
# Read the design timing table, including pulse width, and fail on format drift.
set fields [regexp -inline -line \
    {^\s*([-0-9.]+)\s+([-0-9.]+)\s+([0-9]+)\s+([0-9]+)\s+([-0-9.]+)\s+([-0-9.]+)\s+([0-9]+)\s+([0-9]+)\s+([-0-9.]+)\s+([-0-9.]+)\s+([0-9]+)\s+([0-9]+)\s*$} $timing]
if {[llength $fields] != 13} {error "Unrecognized timing summary table"}
lassign [lrange $fields 1 end] wns tns setup_fail setup_total whs ths hold_fail hold_total wpws tpws pulse_fail pulse_total
report_exceptions -coverage -file exception_coverage.rpt

# Report each real boundary separately. Missing groups cannot silently pass.
proc path_group {name args} {
    set maxima [get_timing_paths {*}$args -delay_type max -max_paths 1]
    set minima [get_timing_paths {*}$args -delay_type min -max_paths 1]
    if {![llength $maxima] || ![llength $minima]} {error "Missing $name paths"}
    report_timing {*}$args -delay_type max -max_paths 10 -file ${name}_setup.rpt
    report_timing {*}$args -delay_type min -max_paths 10 -file ${name}_hold.rpt
    return [list [get_property SLACK $maxima] [get_property SLACK $minima] \
        [get_property REQUIREMENT $maxima] [get_property REQUIREMENT $minima]]
}
set groups [dict create all [path_group all]]
set physical_boundary 0
if {$context eq "registered"} {
    set launch [get_cells context_launch_*]
    set capture [get_cells context_capture_*]
    set core [filter [all_registers] {NAME !~ context_*}]
    dict set groups ingress [path_group ingress -from $launch -to $core]
    dict set groups egress [path_group egress -from $core -to $capture]
    dict set groups bypass [path_group bypass -from $launch -to $capture]
    dict set groups internal [path_group internal -from $core -to $core]
    # Prove the tighter setup budgets and unmodified same-edge hold checks exist.
    foreach {group budget} {ingress 8.0 egress 8.0 bypass 6.0} {
        lassign [dict get $groups $group] gs gh setup_req hold_req
        if {abs($setup_req - $budget) > 0.001 || abs($hold_req) > 0.001} {
            error "$group setup/hold requirement does not match its contract"
        }
    }
    if {[llength [get_ports]] != 1 || [get_ports] ne "clk" ||
        [llength $launch] != [llength $context_launch] ||
        [llength $capture] != [llength $context_capture]} {
        error "Physical context lost an interface endpoint"
    }
    set clock_net [get_nets -of_objects [get_pins context_clock_buffer/O]]
    if {[get_property ROUTE_STATUS $clock_net] ne "ROUTED"} {
        error "Context clock tree is not physically routed"
    }
    set physical_boundary 1
} else {
    dict set groups ingress [path_group ingress -from [get_ports -filter {DIRECTION == IN && NAME != clk}]]
    dict set groups egress [path_group egress -to [all_outputs]]
    dict set groups internal [path_group internal -from [all_registers] -to [all_registers]]
}
set summary "Vivado: [version -short]\nTop: $top\nPart: $part\nContext: $context\n"
append summary "Clock: 100 MHz; setup/hold uncertainty: 0.1/0.05 ns\n"
if {$context eq "registered"} {
    append summary "Contract: real same-clock BUFG/FDRE boundary; setup budgets 8/8/6 ns\n"
    append summary "Fixture registers: [llength $launch] launch, [llength $capture] capture\n"
    append summary "Clock buffer location: [get_property LOC [get_cells context_clock_buffer]]\n"
} else {
    append summary "Contract: abstract I/O max/min 2.0/0.2 ns; parent clock/boundary unknown\n"
}
dict for {name values} $groups {
    lassign $values gs gh sr hr
    append summary "$name: setup_slack=$gs hold_slack=$gh setup_requirement=$sr hold_requirement=$hr ns\n"
}
append summary "Timing endpoints: setup=$setup_total hold=$hold_total pulse_width=$pulse_total\n"
append summary "Failing endpoints: setup=$setup_fail hold=$hold_fail pulse_width=$pulse_fail\n"
append summary "Pulse width worst slack: $wpws ns\n"
append summary "Timing coverage issues: $coverage_errors\nDRC errors: $drc_errors\n"
append summary "Routing fully complete: $fully_routed\nRouting errors: $route_errors\n"
append summary "Physical data/clock context: $physical_boundary\nScope: reference integration only; no board pins or bitstream\n"
save_text result.txt $summary
if {$setup_fail || $hold_fail || $pulse_fail || $coverage_errors || $drc_errors ||
    !$fully_routed || $route_errors || !$physical_boundary} {
    error "Timing/routing/coverage/physical-context gate failed; inspect result.txt"
}
# Batch exit codes can be lost by Windows wrappers: require this final marker.
set f [open result.txt a]
puts $f "Implementation status: PASS"
close $f
puts "IMPLEMENTATION_PASS top=$top context=$context setup=$wns hold=$whs"
exit 0
