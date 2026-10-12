# Single-source synthesis accounting. This does not establish CDC or system
# timing closure: there is no implementation run or custom false-path exception.
# Vivado applies the original XPM-scoped constraints automatically.
# Usage: vivado -mode batch -source scripts/rfnoc_source_synth.tcl \
#          -tclargs <output-directory> <manifest-generated-sources.tcl>
# The generated file defines uhd_sources and uhd_include_dirs as Tcl lists.
if {$argc != 2} {
    error "Expected output directory and manifest-generated sources.tcl"
}
set output [file normalize [lindex $argv 0]]
set sources_file [file normalize [lindex $argv 1]]
set root [file normalize [file join [file dirname [info script]] ..]]
file mkdir $output
file delete -force [file join $output result.txt]

source $sources_file
if {![info exists uhd_sources] || ![info exists uhd_include_dirs]} {
    error "sources.tcl must define uhd_sources and uhd_include_dirs"
}
create_project -in_memory -part xc7z020clg400-2
set_property source_mgmt_mode None [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
set_property include_dirs $uhd_include_dirs [current_fileset]
read_verilog -sv $uhd_sources
read_verilog -sv [file join $root sim rfnoc_source.sv]
synth_design -top rfnoc_source -part xc7z020clg400-2 \
    -mode out_of_context -flatten_hierarchy rebuilt

create_clock -name radio_clk -period 12.500 [get_ports radio_clk]
create_clock -name ctrl_clk -period 10.000 [get_ports ctrl_clk]
report_clocks -file [file join $output clocks.rpt]
report_utilization -file [file join $output utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 8 \
    -file [file join $output utilization_hierarchical.rpt]
write_checkpoint -force [file join $output source_synth.dcp]

set result [open [file join $output result.txt] w]
puts $result "status=SYNTHESIS_COMPLETE"
puts $result "top=rfnoc_source"
puts $result "source_instances=1"
puts $result "part=xc7z020clg400-2"
puts $result "radio_period_ns=12.500"
puts $result "ctrl_period_ns=10.000"
puts $result "timing_status=NOT_EVALUATED"
puts $result "implementation=NOT_RUN"
puts $result "custom_false_paths_added=0"
puts $result "vendor_xpm_constraints=APPLIED_BY_VIVADO"
puts $result "tool=[version -short]"
close $result
close_project
