# Physical, single-clock integration fixture for an already synthesized DUT.
# Not functional traffic and not a board wrapper. The DUT RTL is unchanged.
# Real launch/capture FDREs replace abstract input/output timing ports; a BUFG
# supplies a shared physical clock tree. Preserve the existing clock/uncertainty.
# Record boundary mapping for the implementation reporter.
file delete -force result.txt
set_operating_conditions -grade industrial
set context_core [all_registers]
set context_clock_port [get_ports -quiet {clk aclk}]
if {[llength $context_clock_port] != 1} {error "Expected exactly one clk or aclk input port"}
set context_inputs [lsort -dictionary [get_ports -filter {DIRECTION == IN && NAME != clk && NAME != aclk}]]
set context_outputs [lsort -dictionary [get_ports -filter {DIRECTION == OUT}]]
if {![llength $context_inputs] || ![llength $context_outputs] || ![llength $context_core]} {
    error "Registered context requires a sequential DUT with inputs and outputs"
}
if {[llength [get_cells -quiet context_*]]} {error "Reserved context_ cell prefix already used"}
set context_clock_net [get_nets -of_objects $context_clock_port]
if {[llength $context_clock_port] != 1 || [llength $context_clock_net] != 1} {
    error "Registered context requires one clock port/net"
}
disconnect_net -net $context_clock_net -objects $context_clock_port
create_net context_clock_in
connect_net -net [get_nets context_clock_in] -objects $context_clock_port
create_cell -reference BUFG context_clock_buffer
connect_net -net [get_nets context_clock_in] -objects [get_pins context_clock_buffer/I]
connect_net -net $context_clock_net -objects [get_pins context_clock_buffer/O]
set_property DONT_TOUCH true [get_cells context_clock_buffer]
create_cell -reference VCC context_vcc
create_net context_one
connect_net -net [get_nets context_one] -objects [get_pins context_vcc/P]
create_cell -reference GND context_gnd
create_net context_zero
connect_net -net [get_nets context_zero] -objects [get_pins context_gnd/G]

# All fixture registers have CE=1 and R=0. Only fixture cells are preserved;
# no DUT cell is frozen or functionally modified by this script.
proc context_register {name clock_net} {
    create_cell -reference FDRE $name
    set_property DONT_TOUCH true [get_cells $name]
    connect_net -net $clock_net -objects [get_pins $name/C]
    connect_net -net [get_nets context_one] -objects [get_pins $name/CE]
    connect_net -net [get_nets context_zero] -objects [get_pins $name/R]
}
set context_launch {}
set context_capture {}
set context_capture_nets {}
set context_map [open context_ports.txt w]
set index 0
foreach port $context_outputs {
    set name context_capture_$index
    set data_net [get_nets -of_objects $port]
    if {[llength $data_net] != 1} {error "Output $port has no unique net"}
    context_register $name $context_clock_net
    connect_net -net $data_net -objects [get_pins $name/D]
    create_net ${name}_q
    connect_net -net [get_nets ${name}_q] -objects [get_pins $name/Q]
    lappend context_capture [get_cells $name]
    lappend context_capture_nets [get_nets ${name}_q]
    puts $context_map "CAPTURE $port $name net=$data_net"
    disconnect_net -net $data_net -objects $port
    remove_port $port
    incr index
}
set index 0
foreach port $context_inputs {
    set name context_launch_$index
    set data_net [get_nets -quiet -of_objects $port]
    # Disabled optional KEEP inputs can survive synthesis as ports without nets.
    # They have no timing path; reject all other missing/ambiguous connections.
    if {![llength $data_net] && [info exists keep_enable] && !$keep_enable &&
        [regexp {^s_(axis_t)?keep\[[0-9]+\]$} $port]} {
        puts $context_map "UNUSED_KEEP $port KEEP_ENABLE=0"
        remove_port $port
        continue
    }
    if {[llength $data_net] != 1} {error "Input $port has no unique net"}
    context_register $name $context_clock_net
    # Registered feedback gives every launch input a physical driver without
    # creating new external data ports. It is not a protocol stimulus source.
    set feedback [lindex $context_capture_nets [expr {$index % [llength $context_capture_nets]}]]
    connect_net -net $feedback -objects [get_pins $name/D]
    puts $context_map "LAUNCH $port $name net=$data_net feedback=$feedback"
    disconnect_net -net $data_net -objects $port
    remove_port $port
    connect_net -net $data_net -objects [get_pins $name/Q]
    lappend context_launch [get_cells $name]
    incr index
}
close $context_map
rename context_register {}
if {[llength [get_ports]] != 1} {error "Unwrapped ports remain in registered context"}

# Reserve the original 2 ns maximum allowance at each interface. These budgets
# include real fixture tCQ/setup, so they are conservative setup requirements.
# No datapath-only/min-delay/false-path exception: natural same-clock hold stays
# enabled. The former 0.2 ns external input assumption is NOT an equivalent
# model for the actual launch FDRE's tCQ and shared clock insertion/skew.
set_max_delay 8.000 -from $context_launch -to $context_core
set_max_delay 8.000 -from $context_core -to $context_capture
set_max_delay 6.000 -from $context_launch -to $context_capture
puts "REGISTERED_CONTEXT launch=[llength $context_launch] capture=[llength $context_capture] core=[llength $context_core]"
