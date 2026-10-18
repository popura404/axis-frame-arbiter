# Use scripts/build.py: outputs stay in build/vivado/<top>/pN-wW-dD/<context>.
# registered = physical same-clock reference integration, NOT a board bitstream.
# ports = original abstract OOC interface budget; diagnostic only without a parent.
set root [file normalize [file join [file dirname [info script]] ..]]
set top stream_arbiter
set context registered
set ports 4
set width 32
set depth 64
if {$argc ni {0 1 2 5 6 7 8 9 10}} {
    error "Usage: vivado.tcl ?top? ?registered|ports? ?ports width depth? ?admission_csv? ?frame_fifo? ?packet_mode? ?max_frame_beats? ?keep_enable?"
}
if {$argc >= 1} {set top [lindex $argv 0]}
if {$argc >= 2} {set context [lindex $argv 1]}
if {$argc >= 5} {lassign [lrange $argv 2 4] ports width depth}
if {$top ni {stream_arbiter axis_stream_arbiter stream_selftest axis_external} ||
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
if {$argc >= 6} {set levels [split [lindex $argv 5] ,]}
if {[llength $levels] == 1} {set levels [lrepeat $ports [lindex $levels 0]]}
if {[llength $levels] != $ports} {error "One admission value per port is required"}
set frame_fifo 0
if {$argc >= 7} {set frame_fifo [lindex $argv 6]}
if {$frame_fifo ni {0 1}} {error "FRAME_FIFO must be 0 or 1"}
if {$top ne "axis_external" && $frame_fifo} {error "FRAME_FIFO is external-only"}
set packet_mode 0
set max_frame_beats $depth
set keep_enable 0
if {$argc >= 8} {set packet_mode [lindex $argv 7]}
if {$argc >= 9} {set max_frame_beats [lindex $argv 8]}
if {$argc >= 10} {set keep_enable [lindex $argv 9]}
if {$packet_mode ni {0 1}} {error "PACKET_MODE must be 0 or 1"}
if {$keep_enable ni {0 1}} {error "KEEP_ENABLE must be 0 or 1"}
if {$keep_enable && ($top ni {stream_arbiter axis_stream_arbiter} || !$packet_mode)} {
    error "KEEP_ENABLE requires packet mode on the local core or AXIS top"
}
if {$top ni {stream_arbiter axis_stream_arbiter} && ($packet_mode || $argc >= 9)} {
    error "PACKET_MODE/MAX_FRAME_BEATS apply only to the local core and AXIS tops"
}
if {![string is integer -strict $max_frame_beats] || $max_frame_beats < 1 || $max_frame_beats > $depth} {
    error "MAX_FRAME_BEATS must be an integer in 1..FIFO_DEPTH"
}
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
if {$top eq "axis_external" && $nondefault} {error "External reference has no admission parameter"}
if {$packet_mode && $nondefault} {error "Packet mode requires H=1 on every lane"}
set configuration p${ports}-w${width}-d${depth}
if {$nondefault} {append configuration -h[join $levels -]}
if {$packet_mode} {append configuration -packet-m${max_frame_beats}}
if {$keep_enable} {append configuration -keep1}
if {$top eq "axis_external"} {append configuration -frame${frame_fifo}}
set out_dir [file join $root build vivado $top $configuration $context]
file mkdir $out_dir
cd $out_dir
file delete -force result.txt
set part xc7z020clg400-2
create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_param general.maxThreads 4
read_verilog -sv [lsort [glob [file join $root rtl *.sv]]]
if {$top eq "axis_external"} {
    read_verilog -sv [file join $root sim axis_external.sv]
    foreach source {axis_fifo.v axis_arb_mux.v arbiter.v priority_encoder.v} {
        read_verilog [file join $root build vendor verilog-axis rtl $source]
    }
}
read_xdc [file join $root scripts clock.xdc]
set synth_args [list -top $top -part $part -mode out_of_context]
if {$top ne "stream_selftest"} {
    foreach generic [list PORTS=$ports DATA_WIDTH=$width FIFO_DEPTH=$depth] {
        lappend synth_args -generic $generic
    }
    if {$top eq "axis_external"} {
        lappend synth_args -generic FRAME_FIFO=$frame_fifo
    } else {
        lappend synth_args -generic "ADMISSION_LEVELS=[expr {$ports*5}]'d$admission"
        lappend synth_args -generic PACKET_MODE=$packet_mode -generic MAX_FRAME_BEATS=$max_frame_beats
        lappend synth_args -generic KEEP_ENABLE=$keep_enable
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
source [file join $root scripts report_reference.tcl]
exit 0
