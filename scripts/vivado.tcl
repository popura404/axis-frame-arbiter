# Use scripts/build.py: outputs stay in build/vivado/<top>/pN-wW-dD/<context>.
# registered = physical same-clock reference integration, NOT a board bitstream.
# ports = original abstract OOC interface budget; diagnostic only without a parent.
set root [file normalize [file join [file dirname [info script]] ..]]
set top stream_arbiter
set context registered
set ports 4
set width 32
set depth 64
if {$argc ni {0 1 2 5 6}} {
    error "Usage: vivado.tcl ?top? ?registered|ports? ?ports width depth? ?admission_csv?"
}
if {$argc >= 1} {set top [lindex $argv 0]}
if {$argc >= 2} {set context [lindex $argv 1]}
if {$argc >= 5} {lassign [lrange $argv 2 4] ports width depth}
if {$top ni {stream_arbiter axis_stream_arbiter stream_selftest} ||
    $context ni {registered ports}} {
    error "Unsupported top/context"
}
foreach {name value allowed} [list PORTS $ports {2 4 8} DATA_WIDTH $width {32 64} FIFO_DEPTH $depth {16 64}] {
    if {![string is integer -strict $value] || $value ni $allowed} {
        error "Unsupported $name=$value; allowed values: $allowed"
    }
}
if {$top eq "stream_selftest" && ($ports != 4 || $width != 32 || $depth != 64)} {
    error "stream_selftest uses the fixed 4-port, 32-bit, depth-64 configuration"
}
set levels [lrepeat $ports 1]
if {$argc == 6} {set levels [split [lindex $argv 5] ,]}
if {[llength $levels] == 1} {set levels [lrepeat $ports [lindex $levels 0]]}
if {[llength $levels] != $ports} {error "One admission value per port is required"}
set admission 0
set nondefault 0
set lane 0
foreach level $levels {
    if {![string is integer -strict $level] || $level < 1 || $level > 16} {
        error "Admission thresholds must be integers in 1..16"
    }
    set admission [expr {$admission | ($level << (5*$lane))}]
    if {$level != 1} {set nondefault 1}
    incr lane
}
if {$top eq "stream_selftest" && $nondefault} {error "stream_selftest requires H=1"}
set configuration p${ports}-w${width}-d${depth}
if {$nondefault} {append configuration -h[join $levels -]}
set out_dir [file join $root build vivado $top $configuration $context]
file mkdir $out_dir
cd $out_dir
file delete -force result.txt
set part xc7z020clg400-2
create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_param general.maxThreads 4
read_verilog -sv [lsort [glob [file join $root rtl *.sv]]]
read_xdc [file join $root scripts clock.xdc]
set synth_args [list -top $top -part $part -mode out_of_context]
if {$top ne "stream_selftest"} {
    foreach generic [list PORTS=$ports DATA_WIDTH=$width FIFO_DEPTH=$depth "ADMISSION_LEVELS=[expr {$ports*5}]'d$admission"] {
        lappend synth_args -generic $generic
    }
}
synth_design {*}$synth_args
if {[llength [get_ports -quiet {clk aclk}]] != 1} {
    error "Expected exactly one clk or aclk input port"
}
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
# Final timing, coverage and physical-context gates.
file delete -force result.txt
if {![info exists top]} {set top [get_property TOP [current_fileset]]}
if {$top eq ""} {set top [get_property NAME [current_design]]}
set part [get_property PART [current_design]]
set clock_port [get_ports -quiet {clk aclk}]
if {[llength $clock_port] != 1} {error "Expected exactly one clk or aclk input port"}
set clock_port_name [get_property NAME $clock_port]
# Batch passes an explicit configuration. A GUI run may use project generics;
# do not infer defaults from the port names or from the selected top.
set reported_configuration "unknown (project settings)"
if {[info exists configuration]} {set reported_configuration $configuration}
set context [expr {[llength [get_cells -quiet context_clock_buffer]] ? "registered" : "ports"}]
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
    # The mapping survives project-run restarts; Tcl object variables do not.
    set mapped [dict create LAUNCH 0 CAPTURE 0]
    set map_file [open context_ports.txt r]
    foreach line [split [read $map_file] "\n"] {
        if {[regexp {^(LAUNCH|CAPTURE) } $line -> direction]} {
            dict incr mapped $direction
        }
    }
    close $map_file
    if {[llength [get_ports]] != 1 || [get_property NAME [get_ports]] ne $clock_port_name ||
        [llength $launch] != [dict get $mapped LAUNCH] ||
        [llength $capture] != [dict get $mapped CAPTURE]} {
        error "Physical context lost an interface endpoint"
    }
    set clock_net [get_nets -of_objects [get_pins context_clock_buffer/O]]
    if {[get_property ROUTE_STATUS $clock_net] ne "ROUTED"} {
        error "Context clock tree is not physically routed"
    }
    set physical_boundary 1
} else {
    dict set groups ingress [path_group ingress -from [get_ports -filter {DIRECTION == IN && NAME != clk && NAME != aclk}]]
    dict set groups egress [path_group egress -to [all_outputs]]
    dict set groups internal [path_group internal -from [all_registers] -to [all_registers]]
}
set summary "Vivado: [version -short]\nTop: $top\nPart: $part\nContext: $context\n"
append summary "Configuration: $reported_configuration\nClock port: $clock_port_name\n"
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
puts "IMPLEMENTATION_PASS top=$top config=$reported_configuration context=$context setup=$wns hold=$whs"
exit 0
