`timescale 1ns/1ps
module tb_fifo;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, s_valid=0, m_ready=0;
    reg [32:0] s_data=0;
    wire s_ready, m_valid, next_valid; wire [32:0] m_data; wire [6:0] level;
    sync_fifo dut(.*);
    reg [32:0] queue[0:4095];
    integer head=0,tail=0,checks=0;
    reg held_valid=0; reg [32:0] held;
    task tick(input bit reset, input bit valid, input bit ready, input [32:0] data);
        begin
            @(negedge clk); rst=reset; s_valid=valid; m_ready=ready; s_data=data;
            @(posedge clk);
            if (rst) begin head=0;tail=0;held_valid=0; end
            else begin
                if (level !== tail-head) $fatal(1,"level mismatch");
                if (m_valid !== (tail!=head)) $fatal(1,"empty mismatch");
                if (s_ready !== (tail-head<64)) $fatal(1,"full mismatch");
                if (held_valid && (!m_valid || m_data !== held)) $fatal(1,"head changed under stall");
                if (m_valid && m_data !== queue[head]) $fatal(1,"data mismatch");
                held_valid=m_valid&&!m_ready; held=m_data;
                if (m_valid&&m_ready) begin head=head+1;checks=checks+1;end
                if (s_valid&&s_ready) begin queue[tail]=s_data;tail=tail+1;end
                if (next_valid !== (tail!=head)) $fatal(1,"next occupancy mismatch");
            end
            #1;
        end
    endtask
    integer i;
    initial begin
        tick(1,0,0,0);
        tick(0,0,1,0); // empty read is ignored
        for(i=0;i<64;i=i+1) tick(0,1,0,{i[0],32'h1000+i});
        for(i=0;i<4;i=i+1) tick(0,1,0,33'h1deadbeef); // full writes ignored
        tick(0,1,1,33'h1badbad00); // full pop, no look-ahead write
        for(i=0;i<256;i=i+1) tick(0,1,1,{i[0],32'h2000+i}); // wrap, concurrent push/pop
        for(i=0;i<64;i=i+1) tick(0,0,1,0);
        tick(0,1,0,33'h112345678); // reset while occupied/stalled
        tick(0,0,0,0);
        tick(1,1,1,0);
        tick(0,1,1,33'h1cafefeed); // empty push is not fall-through
        tick(0,0,1,0);
        tick(0,0,1,0);
        if(head!=tail || checks!=321) $fatal(1,"accounting mismatch %0d",checks);
        $display("PASS fifo: %0d checked pops; full/empty, wrap, simultaneous, stall, reset", checks);
        $finish;
    end
    initial begin #100000; $fatal(1,"watchdog"); end
endmodule
