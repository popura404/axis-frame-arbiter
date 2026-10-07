`timescale 1ns/1ps

// One driver and one independent accepted-transaction scoreboard. No DUT internals.
module tb_stream_arbiter #(
    parameter integer PORTS = 4,
    parameter integer DATA_WIDTH = 32,
    parameter integer FIFO_DEPTH = 64,
    parameter integer AXIS = 0,
    parameter integer EXTERNAL = 0,
    parameter integer FRAME_FIFO = 0,
    parameter integer PACKET_MODE = 0,
    parameter integer MAX_FRAME_BEATS = FIFO_DEPTH,
    parameter integer KEEP_ENABLE = 0,
    parameter [PORTS*5-1:0] ADMISSION_LEVELS = {PORTS{5'd1}}
);
    localparam SOURCE_WIDTH = $clog2(PORTS);
    localparam LEVEL_WIDTH = $clog2(FIFO_DEPTH) + 1;
    localparam KEEP_WIDTH = DATA_WIDTH/8;
    localparam [LEVEL_WIDTH-1:0] FULL_LEVEL = FIFO_DEPTH;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg mode_rr = 0;
    reg [PORTS*DATA_WIDTH-1:0] s_data = 0;
    reg [PORTS*KEEP_WIDTH-1:0] s_keep = {PORTS*KEEP_WIDTH{1'b1}};
    reg [PORTS-1:0] s_last = 0, s_valid = 0;
    wire [PORTS-1:0] s_ready, protocol_error;
    wire [PORTS*LEVEL_WIDTH-1:0] fifo_level;
    wire [DATA_WIDTH-1:0] m_data;
    wire [KEEP_WIDTH-1:0] m_keep;
    wire m_last, m_valid;
    reg m_ready = 0;
    wire [SOURCE_WIDTH-1:0] m_source;

    generate
        if (EXTERNAL) begin : external_interface
            axis_external #(
                .PORTS(PORTS), .DATA_WIDTH(DATA_WIDTH), .FIFO_DEPTH(FIFO_DEPTH),
                .FRAME_FIFO(FRAME_FIFO)
            ) dut (
                .clk(clk), .rst(rst), .s_data(s_data), .s_last(s_last),
                .s_valid(s_valid), .s_ready(s_ready), .m_data(m_data),
                .m_last(m_last), .m_valid(m_valid), .m_ready(m_ready), .m_source(m_source)
            );
            assign fifo_level = 0; // External storage has different capacity/pipeline.
            assign protocol_error = 0; // Input legality is checked by this testbench.
            assign m_keep = {KEEP_WIDTH{1'b1}};
        end else if (AXIS) begin : axi_interface
            axis_stream_arbiter #(
                .PORTS(PORTS), .DATA_WIDTH(DATA_WIDTH), .FIFO_DEPTH(FIFO_DEPTH),
                .ADMISSION_LEVELS(ADMISSION_LEVELS), .PACKET_MODE(PACKET_MODE),
                .MAX_FRAME_BEATS(MAX_FRAME_BEATS), .KEEP_ENABLE(KEEP_ENABLE)
            ) dut (
                .aclk(clk), .aresetn(!rst), .mode_rr(mode_rr),
                .s_axis_tdata(s_data), .s_axis_tlast(s_last),
                .s_axis_tkeep(s_keep), .m_axis_tkeep(m_keep),
                .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
                .m_axis_tdata(m_data), .m_axis_tlast(m_last),
                .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
                .m_axis_tid(m_source), .protocol_error(protocol_error), .fifo_level(fifo_level)
            );
        end else begin : core_interface
            stream_arbiter #(
                .PORTS(PORTS), .DATA_WIDTH(DATA_WIDTH), .FIFO_DEPTH(FIFO_DEPTH),
                .ADMISSION_LEVELS(ADMISSION_LEVELS), .PACKET_MODE(PACKET_MODE),
                .MAX_FRAME_BEATS(MAX_FRAME_BEATS), .KEEP_ENABLE(KEEP_ENABLE)
            ) dut (.*);
        end
    endgenerate

    localparam QSIZE = FIFO_DEPTH + (EXTERNAL ? 5 : 1);
    reg [DATA_WIDTH:0] queue_data [0:PORTS-1][0:QSIZE-1];
    reg [KEEP_WIDTH-1:0] queue_keep [0:PORTS-1][0:QSIZE-1];
    reg queue_good_end [0:PORTS-1][0:QSIZE-1];
    reg [PORTS-1:0] input_frame_fault = 0;
    integer head [0:PORTS-1], tail [0:PORTS-1], queued [0:PORTS-1];
    integer issued [0:PORTS-1], limit [0:PORTS-1], frames [0:PORTS-1];
    integer accepted, delivered, discarded = 0, grand_delivered = 0, grand_accepted = 0;
    integer accepted_bytes = 0, delivered_bytes = 0;
    integer frame_time [0:PORTS-1][0:4095];
    integer in_frames [0:PORTS-1], out_started [0:PORTS-1];
    integer input_frame_beat [0:PORTS-1];
    localparam PACKET_PLAN_SIZE = 4096;
    reg packet_tail [0:PORTS-1][0:PACKET_PLAN_SIZE-1];
    reg [KEEP_WIDTH-1:0] packet_keep [0:PORTS-1][0:PACKET_PLAN_SIZE-1];
    integer packet_end [0:PORTS-1];
    integer win_frames [0:PORTS-1], win_backpressure [0:PORTS-1], win_full [0:PORTS-1], peak [0:PORTS-1];
    integer wait_count [0:PORTS-1], wait_sum [0:PORTS-1], wait_max [0:PORTS-1];
    integer win_cycles = 0, win_beats = 0, win_gaps = 0, win_source_gaps = 0, win_stalls = 0;
    reg measuring = 0, expected_error = 0;
    reg [PORTS-1:0] input_stalled = 0, issue_mask = {PORTS{1'b1}};
    reg [DATA_WIDTH+KEEP_WIDTH:0] input_held [0:PORTS-1];
    integer violation_count = 0, seed = 1, events = 0;
    reg [31:0] rng = 1;
    string event_path;
    integer cycle = 0, ref_grant = -1, ref_cursor = 0, frame_beat = 0, frame_source = 0;
    integer mode = 0, tests = 0, source_gaps = 0, stall_cycles = 0;
    integer full_cycles = 0, tail_stalls = 0;
    reg stalled = 0;
    reg [DATA_WIDTH+SOURCE_WIDTH+KEEP_WIDTH:0] stalled_payload;
    string test_case = "directed";
    integer gap = 1, expect_starve = 0, contract_violations = 0;
    integer contract_misses [0:PORTS-1];
    reg [PORTS-1:0] contract_enable = 0;
    reg allow_contract_violation = 0;

    function automatic integer admission_level(input integer lane);
        admission_level = ADMISSION_LEVELS[lane*5 +: 5];
    endfunction

    // Search accepted, unconsumed transactions for a complete head frame.
    // This deliberately does not reproduce the DUT's completion counter.
    function automatic bit eligible(input integer lane);
        integer n;
        begin
            eligible = !PACKET_MODE && queued[lane] >= admission_level(lane);
            if (PACKET_MODE)
                for (n = 0; n < queued[lane]; n = n + 1)
                    if (queue_good_end[lane][(head[lane]+n)%QSIZE]) eligible = 1;
        end
    endfunction

    // Byte-by-byte reference for this interface's packed low-byte subset.
    function automatic bit legal_keep(input bit last, input reg [KEEP_WIDTH-1:0] keep);
        integer byte_index;
        bit zero_seen, data_seen;
        begin
            legal_keep = 1;
            zero_seen = 0;
            data_seen = 0;
            for (byte_index = 0; byte_index < KEEP_WIDTH; byte_index = byte_index+1) begin
                if (keep[byte_index] === 1'b1) begin
                    data_seen = 1;
                    if (zero_seen) legal_keep = 0;
                end else if (keep[byte_index] === 1'b0) begin
                    zero_seen = 1;
                    if (!last) legal_keep = 0;
                end else legal_keep = 0;
            end
            if (!data_seen) legal_keep = 0;
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] payload(input integer src, input integer index);
        integer word_index;
        begin
            // Every 32-bit chunk varies; a 64-bit truncation cannot pass unnoticed.
            for (word_index = 0; word_index < DATA_WIDTH/32; word_index = word_index + 1)
                payload[word_index*32 +: 32] = index ^ (32'h9e3779b9 * word_index);
            if (KEEP_ENABLE)
                for (word_index = 0; word_index < KEEP_WIDTH; word_index = word_index+1)
                    payload[word_index*8 +: 8] = index + 17*src + 29*word_index;
            payload[DATA_WIDTH-1 -: SOURCE_WIDTH] = src;
        end
    endfunction

    task automatic check(input bit condition, input string message);
        if (!condition)
            $fatal(1, "cycle=%0d MODE=%0d CASE=%s: %s", cycle, mode, test_case, message);
    endtask

    // Called on the sampling edge, before nonblocking DUT state updates.
    task automatic sample;
        integer i, candidate, offset, src, wait_time, byte_index;
        reg tail_transfer;
        reg [KEEP_WIDTH-1:0] accepted_keep;
        begin
            cycle = cycle + 1;
            if (rst) begin
                for (i = 0; i < PORTS; i = i + 1) begin
                    discarded = discarded + queued[i];
                    head[i] = 0;
                    tail[i] = 0;
                    queued[i] = 0;
                    issued[i] = 0;
                    frames[i] = 0;
                    in_frames[i] = 0;
                    out_started[i] = 0;
                    input_frame_beat[i] = 0;
                    contract_misses[i] = 0;
                end
                accepted = 0;
                delivered = 0;
                accepted_bytes = 0;
                delivered_bytes = 0;
                ref_grant = -1;
                ref_cursor = 0;
                frame_beat = 0;
                frame_source = 0;
                stalled = 0;
                input_stalled = 0;
                input_frame_fault = 0;
            end else begin
                if (test_case == "study") study_sample();
                if (!expected_error) check(protocol_error === {PORTS{1'b0}}, "unexpected input protocol error");
                if (measuring) win_cycles = win_cycles + 1;
                for (i = 0; i < PORTS; i = i + 1) begin
                    accepted_keep = KEEP_ENABLE ? s_keep[i*KEEP_WIDTH +: KEEP_WIDTH] : {KEEP_WIDTH{1'b1}};
                    if (input_stalled[i] && (!s_valid[i] || {s_last[i], accepted_keep, s_data[i*DATA_WIDTH +: DATA_WIDTH]} !== input_held[i])) begin
                        violation_count = violation_count + 1;
                        check(expected_error, "source violated ready/valid protocol");
                    end
                    input_stalled[i] = s_valid[i] && !s_ready[i];
                    input_held[i] = {s_last[i], accepted_keep, s_data[i*DATA_WIDTH +: DATA_WIDTH]};
                    if (PACKET_MODE && input_frame_fault[i])
                        check(!s_ready[i], "faulted input lane resumed acceptance before reset");
                    // Independent ready-opportunity contract monitor. A source
                    // may violate this deadline while remaining AXIS-correct.
                    // issued[] counts accepted transactions, never DUT state.
                    if (s_valid[i] && s_ready[i]) contract_misses[i] = 0;
                    else if (contract_enable[i] && issued[i] % 16 != 0 && s_ready[i]) begin
                        contract_misses[i] = contract_misses[i] + 1;
                        if (contract_misses[i] == gap) begin
                            contract_violations = contract_violations + 1;
                            check(allow_contract_violation, "source violated its ready-opportunity contract");
                        end
                    end
                    if (measuring) begin
                        if (test_case == "saturated")
                            check(queued[i] > 0, "saturated fairness requires every source continuously nonempty");
                        if (input_stalled[i]) win_backpressure[i] = win_backpressure[i] + 1;
                        if (queued[i] == FIFO_DEPTH) win_full[i] = win_full[i] + 1;
                        if (queued[i] > peak[i]) peak[i] = queued[i];
                    end
                end
                if (stalled)
                    check(m_valid && {m_source, m_last, m_keep, m_data} === stalled_payload,
                          "output changed or VALID dropped during backpressure");
                stalled = m_valid && !m_ready;
                stalled_payload = {m_source, m_last, m_keep, m_data};
                if (stalled) begin
                    stall_cycles = stall_cycles + 1;
                    if (measuring) win_stalls = win_stalls + 1;
                    if (m_last) tail_stalls = tail_stalls + 1;
                end

                candidate = -1;
                if (!EXTERNAL && ref_grant < 0) begin
                    if (measuring) win_gaps = win_gaps + 1;
                    check(!m_valid, "output presented before grant was registered");
                    // This set is independent of the DUT's FIFO flags or grant state.
                    for (offset = 0; offset < PORTS; offset = offset + 1) begin
                        i = mode ? ((ref_cursor + offset) % PORTS) : offset;
                        if (candidate < 0 && eligible(i)) candidate = i;
                    end
                end else if (!EXTERNAL) begin
                    check(m_valid === (queued[ref_grant] != 0),
                          "authorized nonempty queue did not present data, or empty queue did");
                    if (m_valid)
                        check(m_source == ref_grant, "priority/round-robin selection or grant hold mismatch");
                    else begin
                        source_gaps = source_gaps + 1;
                        if (measuring) win_source_gaps = win_source_gaps + 1;
                    end
                end

                for (i = 0; i < PORTS; i = i + 1) begin
                    if (!EXTERNAL)
                        check(fifo_level[i*LEVEL_WIDTH +: LEVEL_WIDTH] == queued[i], "FIFO level differs from accepted transactions");
                    if (queued[i] == FIFO_DEPTH) full_cycles = full_cycles + 1;
                end

                // Output first: a synchronous empty FIFO cannot consume this edge's input.
                tail_transfer = m_valid && m_ready && m_last;
                if (m_valid && m_ready) begin
                    src = m_source;
                    check(queued[src] > 0, "output has no accepted input");
                    check(m_last === queue_data[src][head[src]][DATA_WIDTH] &&
                          m_keep === queue_keep[src][head[src]], "LAST/KEEP mismatch or source reordering");
                    for (byte_index = 0; byte_index < KEEP_WIDTH; byte_index = byte_index+1)
                        if (queue_keep[src][head[src]][byte_index]) begin
                            check(m_data[byte_index*8 +: 8] === queue_data[src][head[src]][byte_index*8 +: 8],
                                  "valid data byte mismatch or source reordering");
                            delivered_bytes = delivered_bytes+1;
                        end
                    if (m_keep[KEEP_WIDTH-1])
                        check(m_data[DATA_WIDTH-1 -: SOURCE_WIDTH] == src, "payload source identifier mismatch");
                    if (PACKET_MODE) begin
                        if (frame_beat != 0) check(src == frame_source, "packet output switched sources within a frame");
                        check(frame_beat < MAX_FRAME_BEATS, "output packet exceeded MAX_FRAME_BEATS");
                    end else if (!expected_error) begin
                        if (frame_beat != 0) check(src == frame_source, "output switched sources within a frame");
                        check(m_data[3:0] == frame_beat, "output frame interleaved or beat order wrong");
                        check(m_last == (frame_beat == 15), "output frame length/LAST wrong");
                    end
                    if (frame_beat == 0) begin
                        frame_source = src;
                        wait_time = cycle - frame_time[src][out_started[src] % 4096];
                        out_started[src] = out_started[src] + 1;
                        if (measuring) begin
                            wait_count[src] = wait_count[src] + 1;
                            wait_sum[src] = wait_sum[src] + wait_time;
                            if (wait_time > wait_max[src]) wait_max[src] = wait_time;
                        end
                        if (events) $fdisplay(events, "%0d,WAIT,%0d,%0d,0,%0d,0", cycle, src, wait_time, measuring);
                    end
                    if (events) $fdisplay(events, "%0d,OUT,%0d,%08x,%0d,%0d,%x", cycle, src, m_data, m_last, measuring, m_keep);
                    if (measuring) win_beats = win_beats + 1;
                    head[src] = (head[src] + 1) % QSIZE;
                    queued[src] = queued[src] - 1;
                    delivered = delivered + 1;
                    grand_delivered = grand_delivered + 1;
                    if (m_last) begin
                        frames[src] = frames[src] + 1;
                        if (measuring) win_frames[src] = win_frames[src] + 1;
                        ref_cursor = (src + 1) % PORTS;
                        ref_grant = -1;
                        frame_beat = 0;
                    end else frame_beat = frame_beat + 1;
                end
                if (candidate >= 0) ref_grant = candidate;

                for (i = 0; i < PORTS; i = i + 1)
                    if (s_valid[i] && s_ready[i]) begin
                        check(queued[i] < QSIZE-1, "input accepted beyond storage capacity");
                        if (PACKET_MODE ? input_frame_beat[i] == 0 : (issued[i] % 16) == 0) begin
                            frame_time[i][in_frames[i] % 4096] = cycle;
                            in_frames[i] = in_frames[i] + 1;
                        end
                        accepted_keep = KEEP_ENABLE ? s_keep[i*KEEP_WIDTH +: KEEP_WIDTH] : {KEEP_WIDTH{1'b1}};
                        if (PACKET_MODE && ((KEEP_ENABLE && !legal_keep(s_last[i], accepted_keep)) ||
                            (!s_last[i] && input_frame_beat[i]+1 >= MAX_FRAME_BEATS)))
                            input_frame_fault[i] = 1;
                        if (events) $fdisplay(events, "%0d,IN,%0d,%08x,%0d,%0d,%x", cycle, i, s_data[i*DATA_WIDTH +: DATA_WIDTH], s_last[i], measuring, s_keep[i*KEEP_WIDTH +: KEEP_WIDTH]);
                        grand_accepted = grand_accepted + 1;
                        queue_data[i][tail[i]] = {s_last[i], s_data[i*DATA_WIDTH +: DATA_WIDTH]};
                        queue_keep[i][tail[i]] = accepted_keep;
                        queue_good_end[i][tail[i]] = s_last[i] && !input_frame_fault[i];
                        for (byte_index = 0; byte_index < KEEP_WIDTH; byte_index = byte_index+1)
                            if (accepted_keep[byte_index]) accepted_bytes = accepted_bytes+1;
                        tail[i] = (tail[i] + 1) % QSIZE;
                        queued[i] = queued[i] + 1;
                        issued[i] = issued[i] + 1;
                        input_frame_beat[i] = s_last[i] ? 0 : input_frame_beat[i] + 1;
                        accepted = accepted + 1;
                    end

                // At a completed frame boundary, the next grant uses accepted
                // transactions AFTER both this edge's read and writes. A sole
                // tail cannot regrant its now-empty source. A new first beat
                // (fixed mode) or completed packet may immediately compete. Idle selection above
                // deliberately retains the existing registered startup cycle.
                if (tail_transfer && !EXTERNAL) begin
                    candidate = -1;
                    for (offset = 0; offset < PORTS; offset = offset + 1) begin
                        i = mode ? ((ref_cursor + offset) % PORTS) : offset;
                        if (candidate < 0 && eligible(i)) candidate = i;
                    end
                    ref_grant = candidate;
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
            for (i = 0; i < PORTS; i = i + 1) begin
                s_valid[i] = (issued[i] < limit[i]) && (issue_mask[i] || input_stalled[i]);
                s_data[i*DATA_WIDTH +: DATA_WIDTH] = payload(i, issued[i]);
                s_last[i] = PACKET_MODE ? packet_tail[i][issued[i] % PACKET_PLAN_SIZE] : (issued[i] % 16) == 15;
                // Disabled KEEP is intentionally driven with masks outside the
                // supported subset; the core must ignore them and emit all ones.
                s_keep[i*KEEP_WIDTH +: KEEP_WIDTH] = KEEP_ENABLE ? packet_keep[i][issued[i] % PACKET_PLAN_SIZE] : issued[i];
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
            for (i = 0; i < PORTS; i = i + 1)
                if (issued[i] != limit[i]) input_done = 0;
        end
    endfunction

    task automatic reset_epoch;
        integer i;
        begin
            rst = 1;
            expected_error = 0;
            contract_enable = 0;
            allow_contract_violation = 0;
            issue_mask = {PORTS{1'b1}};
            mode_rr = mode;
            s_valid = 0;
            s_keep = {PORTS*KEEP_WIDTH{1'b1}};
            m_ready = 0;
            for (i = 0; i < PORTS; i = i + 1) begin
                limit[i] = 0;
                packet_end[i] = 0;
            end
            tick();
            tick();
            check(!m_valid && s_ready == 0 && protocol_error == 0 && fifo_level == 0, "reset failed to clear state");
            rst = 0;
            tests = tests + 1;
        end
    endtask

    task automatic admission;
        integer h, safe_h, n, i, slow, fast, before_gaps, before_violations;
        integer upward_checks, downward_checks, incomplete_checks, violation_checks;
        begin
            h = admission_level(0);
            safe_h = 16 - 15/gap;
            check(gap == 1 || gap == 2 || gap == 4 || gap == 8, "GAP must be 1, 2, 4 or 8");
            check(expect_starve == 0 || expect_starve == 1, "EXPECT_STARVE must be 0 or 1");
            if (expect_starve)
                check(h == safe_h-1 && h > 0, "underflow boundary requires lane 0 H=H*-1>0");
            else check(h >= safe_h, "safe admission requires lane 0 H>=H*");
            upward_checks = 0;
            downward_checks = 0;
            incomplete_checks = 0;
            violation_checks = 0;

            // A different source is at its blocked tail. Lane 0's Hth input
            // arrives on that tail's transfer edge: q0=H, contract phase=0.
            // This reaches the worst phase that an idle-current-q test misses.
            reset_epoch();
            limit[PORTS-1] = 16;
            cycles(18);
            m_ready = 1;
            cycles(15);
            check(m_valid && m_last && m_source == PORTS-1, "admission tail setup failed");
            m_ready = 0;
            cycles(3);
            contract_enable[0] = 1;
            limit[0] = h-1;
            cycles(h-1);
            check(queued[0] == h-1 && m_valid && m_last, "threshold crossing setup failed");
            limit[0] = h;
            m_ready = 1;
            cycles(1);
            check(queued[0] == h && m_valid && m_source == 0 && !m_last,
                  "tail-edge threshold crossing did not authorize the new frame");
            upward_checks = upward_checks + 1;
            before_gaps = source_gaps;
            before_violations = contract_violations;
            limit[0] = 16;
            for (n = 1; n <= 16; n = n + 1) begin
                if (expect_starve && n == 16)
                    check(!m_valid && frame_beat == 15 && queued[0] == 0,
                          "H*-1 did not expose the expected 16th-opportunity underflow");
                else check(m_valid && m_source == 0,
                           "legal supply unexpectedly starved before the predicted boundary");
                issue_mask[0] = (n % gap) == 0;
                cycles(1);
            end
            check(source_gaps-before_gaps == expect_starve,
                  "unexpected source-gap count at the safe/unsafe boundary");
            issue_mask = {PORTS{1'b1}};
            drain();
            check(contract_violations == before_violations && protocol_error == 0,
                  "tight boundary traffic must obey both the contract and AXIS");
            check(frames[0] == 1 && frames[PORTS-1] == 1, "boundary frame completion mismatch");

            // Before this tail q=H includes one old tail plus H-1 new beats.
            // Without a simultaneous push, the remaining prefix is ineligible.
            reset_epoch();
            limit[0] = 16;
            cycles(18);
            limit[0] = 16+h-1;
            m_ready = 1;
            cycles(15);
            m_ready = 0;
            cycles(2);
            check(m_valid && m_last && queued[0] == h, "downward threshold setup failed");
            m_ready = 1;
            cycles(1);
            check(queued[0] == h-1 && !m_valid, "tail pop incorrectly reauthorized a subthreshold prefix");
            cycles(2);
            downward_checks = downward_checks + 1;
            limit[0] = 32;
            drain();

            // An unknown-supply source with H=16 may pause mid-frame without
            // locking out a complete competitor. Also exercises heterogeneous
            // thresholds; use another H>1 lane when this configuration has no 16.
            slow = -1;
            for (i = 0; i < PORTS; i = i + 1)
                if (admission_level(i) == 16 && slow < 0) slow = i;
            if (slow < 0)
                for (i = 0; i < PORTS; i = i + 1)
                    if (admission_level(i) > 1 && slow < 0) slow = i;
            if (slow >= 0) begin
                fast = (slow + 1) % PORTS;
                reset_epoch();
                limit[slow] = admission_level(slow)-1;
                m_ready = 1;
                cycles(20);
                check(delivered == 0, "subthreshold source started before admission");
                limit[fast] = 16;
                cycles(40);
                check(frames[fast] == 1 && frames[slow] == 0 &&
                      queued[slow] == admission_level(slow)-1,
                      "an incomplete unadmitted source blocked its complete competitor");
                limit[slow] = 16;
                drain();
                incomplete_checks = incomplete_checks + 1;
            end

            // A deliberate contract violation remains AXIS-legal. Once a
            // partial frame is active, stopping that source blocks competitors;
            // supplying its remainder recovers without loss, drop or preemption.
            slow = -1;
            for (i = 0; i < PORTS; i = i + 1)
                if (admission_level(i) < 16 && slow < 0) slow = i;
            if (slow >= 0) begin
                fast = (slow + 1) % PORTS;
                reset_epoch();
                contract_enable[slow] = 1;
                allow_contract_violation = 1;
                before_violations = contract_violations;
                before_gaps = source_gaps;
                limit[slow] = admission_level(slow);
                cycles(admission_level(slow)+2);
                m_ready = 1;
                cycles(admission_level(slow)+gap+2);
                check(!m_valid && source_gaps > before_gaps && protocol_error == 0,
                      "contract violation did not produce AXIS-legal active-frame starvation");
                limit[fast] = 16;
                cycles(20);
                check(frames[fast] == 0 && queued[fast] == 16,
                      "competitor escaped a locked incomplete frame");
                limit[slow] = 16;
                drain();
                check(contract_violations == before_violations+1 && protocol_error == 0,
                      "contract violation accounting or legal recovery failed");
                violation_checks = violation_checks + 1;
            end

            // Reset during an active frame with queued competitors, then use
            // the same scoreboard to confirm all stale state was discarded.
            reset_epoch();
            for (i = 0; i < PORTS; i = i + 1) limit[i] = 16;
            cycles(18);
            m_ready = 1;
            cycles(5);
            check(frame_beat == 5 && accepted > delivered, "admission reset setup failed");
            reset_epoch();
            check(discarded > 0, "admission reset did not discard outstanding input");
            limit[0] = 16;
            drain();
            $display("ADMISSION GAP=%0d H0=%0d expected_starve=%0d upward=%0d downward=%0d incomplete_competitor=%0d violation_recovery=%0d contract_violations=%0d",
                     gap, h, expect_starve, upward_checks, downward_checks,
                     incomplete_checks, violation_checks, contract_violations);
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
                check(watchdog < PORTS*8192, "drain timeout (lost data or retained grant)");
            end
            cycles(3);
            check(frame_beat == 0 && !m_valid, "drain ended in an incomplete frame");
            check(accepted == delivered, "drain count mismatch");
            check(accepted_bytes == delivered_bytes, "drain valid-byte count mismatch");
        end
    endtask

    task automatic directed;
        integer i, n;
        begin
            reset_epoch();
            limit[PORTS-1] = 48;
            drain();
            check(frames[PORTS-1] == 3, "single source frame count");

            // Reading the only tail must leave the arbiter idle, not lock an
            // empty source and block a later competitor.
            reset_epoch();
            limit[0] = 16;
            cycles(16);
            m_ready = 1;
            cycles(15);
            check(m_valid && m_last && queued[0] == 1, "sole-tail setup failed");
            cycles(1);
            check(!m_valid && queued[0] == 0, "sole tail did not drain to empty");
            limit[PORTS-1] = 16;
            drain();

            // The first beat of the next frame arrives on the same edge as
            // this source's only buffered tail leaves: no empty-cycle bubble.
            reset_epoch();
            limit[0] = 16;
            cycles(16);
            m_ready = 1;
            cycles(15);
            limit[0] = 32;
            cycles(1);
            check(m_valid && !m_last && m_source == 0 && m_data == payload(0, 16),
                  "same-source tail/refill inserted a bubble or lost the new head");
            drain();

            // An empty competitor becomes eligible on the tail handshake.
            // Last source -> 0 also covers round-robin wrap at this boundary.
            reset_epoch();
            limit[PORTS-1] = 16;
            cycles(16);
            m_ready = 1;
            cycles(15);
            check(m_valid && m_last && queued[PORTS-1] == 1 && queued[0] == 0,
                  "new-competitor boundary setup failed");
            limit[0] = 16;
            cycles(1);
            check(m_valid && !m_last && m_source == 0 && m_data == payload(0, 0),
                  "same-edge competitor was not granted without a bubble");
            drain();

            // Every FIFO fills, with one stable pending beat until reads resume.
            reset_epoch();
            for (i = 0; i < PORTS; i = i + 1) limit[i] = FIFO_DEPTH + 16;
            cycles(FIFO_DEPTH + 10);
            check(fifo_level == {PORTS{FULL_LEVEL}} && s_ready == 0, "all-full backpressure not reached");
            // Configuration is captured by reset and must not change at run time.
            mode_rr = !mode;
            drain();
            for (i = 0; i < PORTS; i = i + 1) check(frames[i] == FIFO_DEPTH/16 + 1, "all-source frame count");

            // Only first/last sources compete; intermediate empty sources are skipped.
            reset_epoch();
            limit[0] = 64;
            limit[PORTS-1] = 64;
            cycles(70);
            drain();
            check(frames[0] == 4 && frames[PORTS-1] == 4, "sparse competition count");

            // The last source owns an incomplete frame. Source 0 cannot steal its grant.
            reset_epoch();
            m_ready = 1;
            limit[PORTS-1] = 5;
            cycles(12);
            check(delivered == 5, "frame prefix did not drain");
            limit[0] = 16;
            cycles(25);
            check(delivered == 5 && queued[0] == 16, "grant lost while source paused");
            limit[PORTS-1] = 16;
            drain();

            // Explicit first-beat and final-beat stalls, including a queued competitor.
            reset_epoch();
            limit[0] = 32;
            limit[PORTS-1] = 32;
            cycles(10);
            check(!m_ready && m_valid && !m_last, "TVALID waited for TREADY or first-beat stall not reached");
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
            m_ready = 1;
            cycles(1);
            check(m_valid && !m_last && m_source == (mode ? PORTS-1 : 0),
                  "stalled tail did not hand over to the next frame without a bubble");
            drain();
            check(source_gaps >= 20 && tail_stalls >= 9 && full_cycles > 0, "directed coverage missing");
        end
    endtask

    function automatic [31:0] random_word;
        reg [31:0] x;
        begin
            x = rng;
            x = x ^ (x << 13);
            x = x ^ (x >> 17);
            x = x ^ (x << 5);
            rng = x;
            random_word = x;
        end
    endfunction

    task automatic randomized;
        integer n, i, watchdog;
        reg [31:0] r;
        begin
            reset_epoch();
            for (i = 0; i < PORTS; i = i + 1) limit[i] = 2048;
            // The first epoch is deliberately reset while accepted traffic is outstanding.
            for (n = 0; n < 1000; n = n + 1) begin
                r = random_word();
                issue_mask = r[PORTS-1:0];
                m_ready = r[8] && (n % 197 < 160);
                cycles(1);
            end
            while (frame_beat == 0) begin
                issue_mask = {PORTS{1'b1}};
                m_ready = 1;
                cycles(1);
            end
            m_ready = 0;
            cycles(1);
            check(frame_beat != 0 && accepted > delivered, "reset coverage requires an active partial frame and outstanding data");
            reset_epoch();
            check(discarded > 0, "reset did not account for discarded input");
            for (i = 0; i < PORTS; i = i + 1) limit[i] = 2048;
            watchdog = 0;
            while (!input_done()) begin
                r = random_word();
                issue_mask = r[PORTS-1:0];
                m_ready = (r[12:9] < 11) && (watchdog % 251 < 210);
                cycles(1);
                watchdog = watchdog + 1;
                check(watchdog < 100000, "random traffic timeout");
            end
            issue_mask = {PORTS{1'b1}};
            drain();
            check(accepted == PORTS*2048 && delivered == PORTS*2048, "random epoch traffic incomplete");
        end
    endtask

    task automatic measurement_start;
        integer i;
        begin
            win_cycles = 0;
            win_beats = 0;
            win_gaps = 0;
            win_source_gaps = 0;
            win_stalls = 0;
            for (i = 0; i < PORTS; i = i + 1) begin
                win_frames[i] = 0;
                win_backpressure[i] = 0;
                win_full[i] = 0;
                peak[i] = 0;
                wait_count[i] = 0;
                wait_sum[i] = 0;
                wait_max[i] = 0;
            end
            measuring = 1;
        end
    endtask

    task automatic performance;
        integer n, i, oldest, min_frames, max_frames, total_frames;
        begin
            reset_epoch();
            // Same open-loop release schedule and downstream schedule in both modes.
            // Warmup fills each active FIFO; measurement begins at a frame boundary.
            for (i = 0; i < PORTS; i = i + 1)
                if (test_case == "saturated" || test_case == "skew" ||
                    (test_case == "single" && i == 0) ||
                    (test_case == "sparse" && (i == 0 || i == PORTS-1))) limit[i] = FIFO_DEPTH;
            cycles(FIFO_DEPTH + 6);
            check(m_valid && !m_ready, "prefilled source waited for TREADY before asserting TVALID");
            m_ready = 1;
            measurement_start();
            for (n = 0; n < 3400; n = n + 1) begin
                for (i = 0; i < PORTS; i = i + 1) begin
                    if ((test_case == "saturated" || (test_case == "single" && i == 0) ||
                        (test_case == "sparse" && (i == 0 || i == PORTS-1))) && n % 16 == 0)
                        limit[i] = limit[i] + 16;
                    if (test_case == "skew" && n % (16 << i) == 0)
                        limit[i] = limit[i] + 16;
                end
                m_ready = (test_case != "skew") || (n % 41 < 31);
                cycles(1);
            end
            measuring = 0;
            check(win_cycles == win_beats + win_gaps + win_source_gaps + win_stalls,
                  "measurement cycle categories do not partition the window");
            $display("METRIC MODE=%0d CASE=%s cycles=%0d beats=%0d beat_per_cycle=%0.6f MBps_at_100MHz=%0.3f arbitration_idle=%0d source_gaps=%0d downstream_stalls=%0d",
                     mode, test_case, win_cycles, win_beats, 1.0*win_beats/win_cycles,
                     (100.0*DATA_WIDTH/8)*win_beats/win_cycles, win_gaps, win_source_gaps, win_stalls);
            total_frames = 0;
            for (i = 0; i < PORTS; i = i + 1) total_frames = total_frames + win_frames[i];
            min_frames = win_frames[0];
            max_frames = win_frames[0];
            for (i = 0; i < PORTS; i = i + 1) begin
                oldest = 0;
                if (in_frames[i] > out_started[i]) oldest = cycle - frame_time[i][out_started[i] % 4096];
                // Request and accepted counts include the FIFO_DEPTH-beat prefill; service/wait statistics use only the window.
                $display("SOURCE MODE=%0d CASE=%s src=%0d completed=%0d share_percent=%0.3f wait_samples=%0d wait_avg=%0.3f wait_max=%0d offered_frames=%0d accepted_beats=%0d queued_beats=%0d unfinished_frames=%0d oldest_unserved=%0d input_blocked=%0d full_cycles=%0d peak=%0d",
                         mode, test_case, i, win_frames[i], total_frames ? 100.0*win_frames[i]/total_frames : 0.0, wait_count[i],
                         wait_count[i] ? 1.0*wait_sum[i]/wait_count[i] : 0.0, wait_max[i],
                         limit[i]/16, issued[i], queued[i], in_frames[i]-frames[i], oldest,
                         win_backpressure[i], win_full[i], peak[i]);
                if (win_frames[i] < min_frames) min_frames = win_frames[i];
                if (win_frames[i] > max_frames) max_frames = win_frames[i];
            end
            if (test_case != "skew" && ADMISSION_LEVELS == {PORTS{5'd1}}) begin
                check(win_beats == 3400 && win_gaps == 0 && total_frames == 212,
                      "continuous load did not sustain one beat per cycle");
            end
            if (test_case == "saturated" && ADMISSION_LEVELS == {PORTS{5'd1}}) begin
                if (mode) check(max_frames-min_frames <= 1, "round-robin saturated fairness failed");
                else check(win_frames[0] == 212 && total_frames == win_frames[0],
                           "fixed-priority saturation should starve lower priority sources");
            end
            // Stop releasing frames, then drain all released traffic, including backlog.
            issue_mask = {PORTS{1'b1}};
            drain();
        end
    endtask

    task automatic negative;
        integer n;
        begin
            reset_epoch();
            expected_error = 1;
            s_valid = 1;
            s_data = 0;
            s_last = 1;
            tick();
            check(protocol_error[0], "early LAST was not detected");
            $display("EXPECTED_ERROR early_LAST detected");

            reset_epoch();
            expected_error = 1;
            limit[1] = 16;
            for (n = 0; n < 16; n = n + 1) begin
                drive();
                s_last[1] = 0;
                tick();
            end
            check(protocol_error[1], "missing LAST was not detected");
            $display("EXPECTED_ERROR missing_LAST detected");

            reset_epoch();
            expected_error = 1;
            m_ready = 1;
            limit[PORTS-1] = 17;
            for (n = 0; n < 17; n = n + 1) begin
                drive();
                s_last[PORTS-1] = n == 16;
                tick();
                if (n < 15) check(!protocol_error[PORTS-1], "late-LAST setup failed before beat 16");
                else check(protocol_error[PORTS-1], "late LAST was not detected at the missing beat-16 LAST");
            end
            $display("EXPECTED_ERROR late_LAST detected");

            reset_epoch();
            limit[PORTS-1] = FIFO_DEPTH + 16;
            cycles(70);
            check(!s_ready[PORTS-1] && s_valid[PORTS-1], "handshake violation setup not stalled");
            expected_error = 1;
            s_data[PORTS*DATA_WIDTH-1] = ~s_data[PORTS*DATA_WIDTH-1];
            tick();
            check(protocol_error[PORTS-1], "stalled data change was not detected");
            $display("EXPECTED_ERROR stalled_DATA_change detected");

            reset_epoch();
            limit[PORTS-1] = FIFO_DEPTH + 16;
            cycles(70);
            expected_error = 1;
            s_valid[PORTS-1] = 0;
            tick();
            check(protocol_error[PORTS-1], "stalled VALID drop was not detected");
            $display("EXPECTED_ERROR stalled_VALID_drop detected");
            check(violation_count == 2, "independent source monitor did not see both handshake violations");
            // A legal post-reset frame confirms sticky errors clear and traffic recovers.
            reset_epoch();
            limit[0] = 16;
            drain();
        end
    endtask

    `include "sim/study_tasks.svh"
    `include "sim/packet_tasks.svh"

    integer init_i;
    // A deadlocked design must fail rather than leave a batch regression hung.
    initial begin
        #2000000;
        $fatal(1, "global simulation timeout");
    end

    initial begin
        for (init_i = 0; init_i < PORTS; init_i = init_i + 1) begin
            queued[init_i] = 0;
            issued[init_i] = 0;
            limit[init_i] = 0;
        end
        if ($value$plusargs("MODE=%d", mode)) begin end
        if ($value$plusargs("CASE=%s", test_case)) begin end
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("GAP=%d", gap)) begin end
        if ($value$plusargs("EXPECT_STARVE=%d", expect_starve)) begin end
        rng = seed ? seed : 1;
        if ($value$plusargs("EVENTS=%s", event_path)) begin
            events = $fopen(event_path, "w");
            check(events != 0, "cannot open EVENTS file");
            $fdisplay(events, "cycle,event,source,data_or_wait,last,measured,keep");
        end
        check(mode == 0 || mode == 1, "MODE must be 0 or 1");
        check(PACKET_MODE == (test_case == "packet"), "PACKET_MODE and packet CASE must agree");
        if (EXTERNAL) check(mode == 1 && test_case == "study", "external reference is RR study only");
        if (test_case == "directed") directed();
        else if (test_case == "admission") admission();
        else if (test_case == "packet") packet_tests();
        else if (test_case == "study") study();
        else if (test_case == "random") randomized();
        else if (test_case == "negative") negative();
        else if (test_case == "single" || test_case == "saturated" || test_case == "skew" || test_case == "sparse") performance();
        else $fatal(1, "unknown CASE=%s", test_case);
        check(grand_accepted == grand_delivered + discarded, "lifetime accepted/delivered/discarded mismatch");
        if (events) $fclose(events);
        $display("PASS stream PORTS=%0d WIDTH=%0d DEPTH=%0d AXIS=%0d PACKET=%0d MAX=%0d KEEP=%0d MODE=%0d CASE=%s epochs=%0d beats=%0d discarded=%0d stalls=%0d tail_stalls=%0d source_gaps=%0d full_cycles=%0d",
                 PORTS, DATA_WIDTH, FIFO_DEPTH, AXIS, PACKET_MODE, MAX_FRAME_BEATS, KEEP_ENABLE, mode, test_case, tests, grand_delivered, discarded, stall_cycles, tail_stalls, source_gaps, full_cycles);
        $finish;
    end
endmodule
