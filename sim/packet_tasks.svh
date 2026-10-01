// Variable-frame stimulus shares the main accepted-transaction scoreboard.
task automatic packet_append(input integer lane, input integer length);
    integer n;
    begin
        check(length > 0 && packet_end[lane]+length < PACKET_PLAN_SIZE, "packet stimulus plan overflow");
        for (n = 0; n < length; n = n + 1)
            packet_tail[lane][packet_end[lane]+n] = n == length-1;
        packet_end[lane] = packet_end[lane] + length;
    end
endtask

task automatic packet_release;
    integer lane;
    begin
        for (lane = 0; lane < PORTS; lane = lane + 1) limit[lane] = packet_end[lane];
    end
endtask

task automatic packet_tests;
    integer n, lane, length, long_length, watchdog, before_violations, before_gaps;
    integer pending_at_fault;
    reg [31:0] r;
    begin
        before_gaps = source_gaps;
        long_length = MAX_FRAME_BEATS < FIFO_DEPTH/2 ? MAX_FRAME_BEATS : FIFO_DEPTH/2;

        // All legal lengths, including both endpoints and non-power-of-two sizes.
        reset_epoch();
        for (length = 1; length <= MAX_FRAME_BEATS; length = length + 1)
            packet_append(length % PORTS, length);
        packet_release();
        watchdog = 0;
        while (!input_done()) begin
            m_ready = watchdog % 11 >= 3;
            cycles(1);
            watchdog = watchdog + 1;
            check(watchdog < PORTS*8192, "packet length sweep timeout");
        end
        drain();

        // D one-beat packets must fit: a completion counter needs to represent D.
        reset_epoch();
        for (n = 0; n < FIFO_DEPTH+2; n = n + 1) packet_append(0, 1);
        limit[0] = FIFO_DEPTH;
        cycles(FIFO_DEPTH+3);
        check(queued[0] == FIFO_DEPTH && !s_ready[0] && m_valid && m_last,
              "single-beat packet completion-count capacity failed");
        limit[0] = packet_end[0];
        cycles(3);
        check(s_valid[0] && !s_ready[0], "packet full-FIFO pending input missing");
        m_ready = 1;
        for (n = 0; n < FIFO_DEPTH; n = n + 1) begin
            check(m_valid && m_last, "committed one-beat packet handoff inserted a bubble");
            cycles(1);
        end
        drain();
        check(frames[0] == FIFO_DEPTH+2, "one-beat packet count wrapped or lost frames");

        // A different lane's input TLAST commits on an outgoing TLAST edge.
        reset_epoch();
        packet_append(PORTS-1, 1);
        limit[PORTS-1] = 1;
        cycles(3);
        length = MAX_FRAME_BEATS < 3 ? MAX_FRAME_BEATS : 3;
        packet_append(0, length);
        limit[0] = length-1;
        cycles(length+2);
        check(m_valid && m_last && m_source == PORTS-1 && queued[0] == length-1,
              "same-edge packet commitment setup failed");
        limit[0] = length;
        m_ready = 1;
        cycles(1);
        check(m_valid && m_source == 0, "newly completed competitor missed the tail handoff");
        drain();

        // One lane completes input and output packets simultaneously, then empties.
        reset_epoch();
        packet_append(0, 1);
        packet_append(0, 1);
        limit[0] = 1;
        cycles(3);
        limit[0] = 2;
        m_ready = 1;
        cycles(1);
        check(m_valid && m_last && m_source == 0, "simultaneous packet increment/decrement lost eligibility");
        cycles(1);
        check(!m_valid, "empty source retained grant after its last completed packet");
        drain();

        if (MAX_FRAME_BEATS > 1) begin
            // Popping the last completed packet leaves a nonempty, unfinished
            // suffix. It must lose eligibility and cannot lock out competitors.
            reset_epoch();
            packet_append(0, 1);
            packet_append(0, MAX_FRAME_BEATS);
            limit[0] = MAX_FRAME_BEATS;
            cycles(MAX_FRAME_BEATS+4);
            check(m_valid && m_last && queued[0] == MAX_FRAME_BEATS,
                  "completed-head/incomplete-suffix setup failed");
            m_ready = 1;
            cycles(MAX_FRAME_BEATS+4);
            check(delivered == 1 && !m_valid && !protocol_error[0], "incomplete suffix retained eligibility or timed out");
            packet_append(PORTS-1, 1);
            packet_append(PORTS-1, MAX_FRAME_BEATS);
            limit[PORTS-1] = packet_end[PORTS-1];
            cycles(2*MAX_FRAME_BEATS+8);
            check(frames[PORTS-1] == 2 && queued[0] == MAX_FRAME_BEATS-1 && !m_valid,
                  "unfinished source blocked completed competitors");
            limit[0] = MAX_FRAME_BEATS+1;
            drain();
        end

        // RR serves one frame per turn, even when frame byte counts differ.
        reset_epoch();
        for (n = 0; n < 2; n = n + 1) begin
            packet_append(0, 1);
            packet_append(PORTS-1, long_length);
        end
        packet_release();
        cycles(2*long_length+3);
        m_ready = 1;
        while (frames[0]+frames[PORTS-1] < 2) cycles(1);
        if (mode) begin
            check(frames[0] == 1 && frames[PORTS-1] == 1 && delivered == 1+long_length,
                  "RR changed from frame turns to byte allocation");
        end else check(frames[0] == 2 && frames[PORTS-1] == 0, "fixed priority did not retain its frame policy");
        drain();

        // First and last beats hold under backpressure; reset discards held data.
        reset_epoch();
        packet_append(0, MAX_FRAME_BEATS);
        limit[0] = MAX_FRAME_BEATS;
        if (MAX_FRAME_BEATS > 1) begin
            packet_append(PORTS-1, MAX_FRAME_BEATS);
            limit[PORTS-1] = MAX_FRAME_BEATS/2;
        end
        cycles(MAX_FRAME_BEATS+4);
        check(m_valid, "complete packet waited for downstream READY");
        m_ready = 1;
        cycles(MAX_FRAME_BEATS-1);
        m_ready = 0;
        cycles(5);
        check(m_valid && m_last && (MAX_FRAME_BEATS == 1 || queued[PORTS-1] == MAX_FRAME_BEATS/2),
              "packet tail or reset's uncommitted-prefix coverage missing");
        reset_epoch();
        packet_append(PORTS-1, 1);
        packet_release();
        drain();

        // A bad unfinished suffix must not prevent its older completed prefix
        // from draining. The faulted lane keeps its accepted, uncommitted data.
        reset_epoch();
        expected_error = 1;
        packet_append(0, 1);
        packet_append(0, MAX_FRAME_BEATS+1);
        limit[0] = packet_end[0];
        cycles(FIFO_DEPTH+3);
        m_ready = 1;
        cycles(MAX_FRAME_BEATS+5);
        check(protocol_error == {{(PORTS-1){1'b0}}, 1'b1} && !s_ready[0],
              "oversized packet did not stop exactly its input lane");
        check(issued[0] == MAX_FRAME_BEATS+1 && frames[0] == 1 && queued[0] == MAX_FRAME_BEATS,
              "oversize boundary accepted too much, exposed a prefix, or trapped old complete data");
        check(s_valid[0] && s_last[0], "oversize test must hold a rejected trailing TLAST");
        pending_at_fault = accepted-delivered;
        packet_append(PORTS-1, MAX_FRAME_BEATS);
        limit[PORTS-1] = packet_end[PORTS-1];
        cycles(2*MAX_FRAME_BEATS+8);
        check(frames[PORTS-1] == 1 && accepted-delivered == pending_at_fault && !m_valid && !s_ready[0],
              "oversize lane blocked a competitor, leaked data, or recovered without reset");
        $display("EXPECTED_ERROR packet_oversize accepted_uncommitted=%0d trailing_LAST_blocked=1", pending_at_fault);
        // No drain() here: this data is intentionally retained until reset.
        reset_epoch();
        packet_append(0, MAX_FRAME_BEATS);
        packet_release();
        drain();

        // Ordinary AXIS stability errors are sticky diagnostics, not quarantine.
        reset_epoch();
        for (n = 0; n < FIFO_DEPTH+1; n = n + 1) packet_append(0, 1);
        packet_release();
        cycles(FIFO_DEPTH+3);
        check(s_valid[0] && !s_ready[0], "packet stability-negative setup was not blocked");
        expected_error = 1;
        before_violations = violation_count;
        s_data[0] = !s_data[0];
        tick();
        s_valid[0] = 0;
        tick();
        check(protocol_error[0] && violation_count == before_violations+2,
              "packet stability errors were not independently detected");
        m_ready = 1;
        drain();
        check(frames[0] == FIFO_DEPTH+1 && protocol_error[0], "ordinary protocol error incorrectly halted input");
        $display("EXPECTED_ERROR packet_stability DATA_change=1 VALID_drop=1 lane_still_serviced=1");

        // Random lengths and interface stalls exercise wraps and repeated commits.
        reset_epoch();
        for (lane = 0; lane < PORTS; lane = lane + 1)
            for (n = 0; n < 48; n = n + 1) begin
                r = random_word();
                packet_append(lane, 1+(r % MAX_FRAME_BEATS));
            end
        packet_release();
        watchdog = 0;
        while (!input_done()) begin
            r = random_word();
            issue_mask = r[PORTS-1:0];
            m_ready = r[12:9] < 11 && watchdog % 97 < 79;
            cycles(1);
            watchdog = watchdog + 1;
            check(watchdog < PORTS*8192, "packet random traffic timeout");
        end
        issue_mask = {PORTS{1'b1}};
        drain();
        for (lane = 0; lane < PORTS; lane = lane + 1)
            check(frames[lane] == 48, "packet random stream lost a frame");
        check(source_gaps == before_gaps, "completed packet suffered source starvation");
        $display("PACKET max=%0d lengths=1..MAX single_beat_capacity=%0d same_edge_commit=2 oversize=1 reset=1 random_frames_per_lane=48",
                 MAX_FRAME_BEATS, FIFO_DEPTH);
    end
endtask
