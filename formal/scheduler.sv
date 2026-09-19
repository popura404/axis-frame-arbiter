`timescale 1ns/1ps
// Unbounded module-level control properties for the actual 2-port scheduler.
// Availability and frame_done are unconstrained interface inputs; this does not
// prove that a parent computes them correctly or that a whole frame completes.
module formal_scheduler(input wire clk);
    reg rst = 1;
    always @(posedge clk) rst <= 0;
    (* anyconst *) reg mode_rr;
    (* anyseq *) reg [1:0] available, available_next;
    (* anyseq *) reg frame_done;
    wire active, source;
    frame_arbiter #(.PORTS(2)) dut(.*);
    reg past_valid = 0;
    reg old_active, old_source, old_done;
    reg [1:0] old_candidates;
    always @(posedge clk) begin
        past_valid <= !rst;
        old_active <= active;
        old_source <= source;
        old_done <= frame_done;
        old_candidates <= frame_done ? available_next : available;
        if (!rst && past_valid) begin
            if (old_active && !old_done) begin
                assert(active);
                assert(source == old_source);
            end else begin
                assert(active == (|old_candidates));
                if (active) begin
                    assert(old_candidates[source]);
                end
            end
            cover(old_active && old_done && active && source != old_source);
            cover(old_active && !old_done && active && available == 0);
        end
    end
endmodule
