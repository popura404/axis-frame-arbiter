`timescale 1ns/1ps

// One driver and one independent accepted-transaction scoreboard. No DUT internals.
module tb_stream_arbiter;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg mode_rr = 0;
    reg [127:0] s_data = 0;
    reg [3:0] s_last = 0, s_valid = 0;
    wire [3:0] s_ready, protocol_error;
    wire [27:0] fifo_level;
    wire [31:0] m_data;
    wire m_last, m_valid;
    reg m_ready = 0;
    wire [1:0] m_source;

    stream_arbiter dut (.*);

    localparam QSIZE = 256;
    reg [32:0] queue_data [0:3][0:QSIZE-1];
    integer head [0:3], tail [0:3], queued [0:3];
    integer issued [0:3], limit [0:3], frames [0:3];
    integer accepted, delivered, discarded = 0, grand_delivered = 0;
    integer cycle = 0, ref_grant = -1, ref_cursor = 0, frame_beat = 0;
    integer mode = 0, tests = 0, source_gaps = 0, stall_cycles = 0;
    integer full_cycles = 0, tail_stalls = 0;
    reg stalled = 0;
    reg [34:0] stalled_payload;
    string test_case = "directed";

    function automatic [31:0] payload(input integer src, input integer index);
        payload = (src << 30) | index;
    endfunction

    task automatic check(input bit condition, input string message);
        if (!condition)
            $fatal(1, "cycle=%0d MODE=%0d CASE=%s: %s", cycle, mode, test_case, message);
    endtask

    // Called on the sampling edge, before nonblocking DUT state updates.
    task automatic sample;
        integer i, candidate, offset, src;
        begin
            cycle = cycle + 1;
            if (rst) begin
                for (i = 0; i < 4; i = i + 1) begin
                    discarded = discarded + queued[i];
                    head[i] = 0;
                    tail[i] = 0;
                    queued[i] = 0;
                    issued[i] = 0;
                    frames[i] = 0;
                end
                accepted = 0;
                delivered = 0;
                ref_grant = -1;
                ref_cursor = 0;
                frame_beat = 0;
                stalled = 0;
            end else begin
                check(protocol_error === 4'b0, "unexpected input protocol error");
                if (stalled)
                    check(m_valid && {m_source, m_last, m_data} === stalled_payload,
                          "output changed or VALID dropped during backpressure");
                stalled = m_valid && !m_ready;
                stalled_payload = {m_source, m_last, m_data};
                if (stalled) begin
                    stall_cycles = stall_cycles + 1;
                    if (m_last) tail_stalls = tail_stalls + 1;
                end

                candidate = -1;
                if (ref_grant < 0) begin
                    check(!m_valid, "output presented before grant was registered");
                    // This set is independent of the DUT's FIFO flags or grant state.
                    for (offset = 0; offset < 4; offset = offset + 1) begin
                        i = mode ? ((ref_cursor + offset) % 4) : offset;
                        if (candidate < 0 && queued[i] != 0) candidate = i;
                    end
                end else begin
                    check(m_valid === (queued[ref_grant] != 0),
                          "authorized nonempty queue did not present data, or empty queue did");
                    if (m_valid)
                        check(m_source == ref_grant, "priority/round-robin selection or grant hold mismatch");
                    else source_gaps = source_gaps + 1;
                end

                for (i = 0; i < 4; i = i + 1) begin
                    check(fifo_level[i*7 +: 7] == queued[i], "FIFO level differs from accepted transactions");
                    if (queued[i] == 64) full_cycles = full_cycles + 1;
                end

                // Output first: a synchronous empty FIFO cannot consume this edge's input.
                if (m_valid && m_ready) begin
                    src = m_source;
                    check(queued[src] > 0, "output has no accepted input");
                    check({m_last, m_data} === queue_data[src][head[src]], "data/LAST mismatch or source reordering");
                    check(m_data[31:30] == src, "payload source identifier mismatch");
                    check(m_data[3:0] == frame_beat, "output frame interleaved or beat order wrong");
                    check(m_last == (frame_beat == 15), "output frame length/LAST wrong");
                    head[src] = (head[src] + 1) % QSIZE;
                    queued[src] = queued[src] - 1;
                    delivered = delivered + 1;
                    grand_delivered = grand_delivered + 1;
                    if (m_last) begin
                        frames[src] = frames[src] + 1;
                        ref_cursor = (src + 1) % 4;
                        ref_grant = -1;
                        frame_beat = 0;
                    end else frame_beat = frame_beat + 1;
                end
                if (candidate >= 0) ref_grant = candidate;

                for (i = 0; i < 4; i = i + 1)
                    if (s_valid[i] && s_ready[i]) begin
                        check(queued[i] < 64, "FIFO accepted beyond capacity");
                        queue_data[i][tail[i]] = {s_last[i], s_data[i*32 +: 32]};
                        tail[i] = (tail[i] + 1) % QSIZE;
                        queued[i] = queued[i] + 1;
                        issued[i] = issued[i] + 1;
                        accepted = accepted + 1;
                    end
            end
        end
    endtask

    task automatic tick;
        begin
            @(posedge clk);
            sample();
            #1;
            @(negedge clk);
        end
    endtask

    task automatic drive;
        integer i;
        begin
            for (i = 0; i < 4; i = i + 1) begin
                s_valid[i] = issued[i] < limit[i];
                s_data[i*32 +: 32] = payload(i, issued[i]);
                s_last[i] = (issued[i] % 16) == 15;
            end
        end
    endtask

    task automatic cycles(input integer count);
        integer n;
        begin
            for (n = 0; n < count; n = n + 1) begin
                drive();
                tick();
            end
        end
    endtask

    function automatic bit input_done;
        integer i;
        begin
            input_done = 1;
            for (i = 0; i < 4; i = i + 1)
                if (issued[i] != limit[i]) input_done = 0;
        end
    endfunction

    task automatic reset_epoch;
        integer i;
        begin
            rst = 1;
            mode_rr = mode;
            s_valid = 0;
            m_ready = 0;
            for (i = 0; i < 4; i = i + 1) limit[i] = 0;
            tick();
            tick();
            check(!m_valid && protocol_error == 0 && fifo_level == 0, "reset failed to clear state");
            rst = 0;
            tests = tests + 1;
        end
    endtask

    task automatic drain;
        integer watchdog;
        begin
            m_ready = 1;
            watchdog = 0;
            while (!input_done() || accepted != delivered) begin
                cycles(1);
                watchdog = watchdog + 1;
                check(watchdog < 20000, "drain timeout (lost data or retained grant)");
            end
            cycles(3);
            check(frame_beat == 0 && !m_valid, "drain ended in an incomplete frame");
            check(accepted == delivered, "drain count mismatch");
        end
    endtask

    task automatic directed;
        integer i, n;
        begin
            reset_epoch();
            limit[2] = 48;
            drain();
            check(frames[2] == 3, "single source frame count");

            // Every FIFO fills, with a stable pending 65th beat until reads resume.
            reset_epoch();
            for (i = 0; i < 4; i = i + 1) limit[i] = 80;
            cycles(90);
            check(fifo_level == {4{7'd64}} && s_ready == 0, "all-full backpressure not reached");
            // Configuration is captured by reset and must not change at run time.
            mode_rr = !mode;
            drain();
            for (i = 0; i < 4; i = i + 1) check(frames[i] == 5, "four-source frame count");

            // Empty sources 1/2 must be skipped; winner 3 advances cursor to 0.
            reset_epoch();
            limit[0] = 64;
            limit[3] = 64;
            cycles(70);
            drain();
            check(frames[0] == 4 && frames[3] == 4, "sparse competition count");

            // Source 3 owns an incomplete frame. Source 0 cannot steal its grant.
            reset_epoch();
            m_ready = 1;
            limit[3] = 5;
            cycles(12);
            check(delivered == 5, "frame prefix did not drain");
            limit[0] = 16;
            cycles(25);
            check(delivered == 5 && queued[0] == 16, "grant lost while source paused");
            limit[3] = 16;
            drain();

            // Explicit first-beat and final-beat stalls, including a queued competitor.
            reset_epoch();
            limit[1] = 32;
            limit[2] = 32;
            cycles(10);
            check(m_valid && !m_last, "first-beat stall not reached");
            m_ready = 1;
            n = 0;
            while (!(m_valid && m_last)) begin
                cycles(1);
                n = n + 1;
                check(n < 100, "tail did not arrive");
            end
            m_ready = 0;
            cycles(9);
            check(m_valid && m_last, "tail not retained under backpressure");
            drain();
            check(source_gaps >= 20 && tail_stalls >= 9 && full_cycles > 0, "directed coverage missing");
        end
    endtask

    integer init_i;
    initial begin
        for (init_i = 0; init_i < 4; init_i = init_i + 1) begin
            queued[init_i] = 0;
            issued[init_i] = 0;
            limit[init_i] = 0;
        end
        if ($value$plusargs("MODE=%d", mode)) begin end
        if ($value$plusargs("CASE=%s", test_case)) begin end
        check(mode == 0 || mode == 1, "MODE must be 0 or 1");
        if (test_case == "directed") directed();
        else $fatal(1, "unknown CASE=%s", test_case);
        $display("PASS stream MODE=%0d CASE=%s epochs=%0d beats=%0d discarded=%0d stalls=%0d tail_stalls=%0d source_gaps=%0d full_cycles=%0d",
                 mode, test_case, tests, grand_delivered, discarded, stall_cycles, tail_stalls, source_gaps, full_cycles);
        $finish;
    end
endmodule
