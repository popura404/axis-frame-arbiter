# Reusable core timing budget, not board pin constraints.
# All ports use the same 100 MHz clock. The enclosing design must meet these
# explicit interface budgets; reset is synchronous and is timed normally.
set core_clock_port [get_ports -quiet {clk aclk}]
# Tcl hooks validate the single clock; XDC files cannot contain an if command.
create_clock -name core_clk -period 10.000 $core_clock_port
set_clock_uncertainty -setup 0.100 [get_clocks core_clk]
set_clock_uncertainty -hold 0.050 [get_clocks core_clk]
set core_inputs [get_ports -filter {DIRECTION == IN && NAME != clk && NAME != aclk}]
set_input_delay -clock core_clk -max 2.000 $core_inputs
set_input_delay -clock core_clk -min 0.200 $core_inputs
set_output_delay -clock core_clk -max 2.000 [all_outputs]
set_output_delay -clock core_clk -min 0.200 [all_outputs]
