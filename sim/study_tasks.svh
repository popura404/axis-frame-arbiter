// Included by the primary accepted-transaction scoreboard. This code records
// interface events; it does not duplicate the DUT or check payload ordering.
localparam integer STUDY_MAX_BEATS = 4096;
localparam integer STUDY_MAX_CYCLES = 32768;
integer study_release[0:PORTS-1][0:STUDY_MAX_BEATS-1];
integer study_count[0:PORTS-1], study_g[0:PORTS-1], study_gap[0:PORTS-1];
integer study_offer[0:PORTS-1][0:STUDY_MAX_BEATS/16-1];
integer study_accept[0:PORTS-1][0:STUDY_MAX_BEATS/16-1];
integer study_first[0:PORTS-1][0:STUDY_MAX_BEATS/16-1];
integer study_complete[0:PORTS-1][0:STUDY_MAX_BEATS/16-1];
reg study_ready_plan[0:STUDY_MAX_CYCLES-1];
integer study_categories[0:6];
integer study_input_beats[0:PORTS-1], study_output_beats[0:PORTS-1];
integer study_blocked[0:PORTS-1], study_peak[0:PORTS-1];
integer study_epoch, study_start, study_end, study_maxcycles;
reg study_active = 0;

task automatic study_sample;
    integer p, n, f, category, after_count;
    reg pending, eligible;
    begin
        if (study_active) begin
            n = cycle - study_epoch;
            pending = 0;
            eligible = 0;
            for (p = 0; p < PORTS; p = p + 1) begin
                pending = pending || queued[p] > 0;
                eligible = eligible || queued[p] >= admission_level(p);
                if (s_valid[p] && s_ready[p]) begin
                    if (issued[p] % 16 == 0)
                        study_accept[p][issued[p]/16] = n;
                    study_gap[p] = 0;
                end else if (issued[p] % 16 != 0 && s_ready[p]) begin
                    study_gap[p] = study_gap[p] + 1;
                    if (study_g[p] > 0)
                        check(study_gap[p] < study_g[p], "study source violated opportunity contract");
                end
                if (n >= study_start && n <= study_end) begin
                    if (s_valid[p] && s_ready[p]) study_input_beats[p] = study_input_beats[p] + 1;
                    if (s_valid[p] && !s_ready[p]) study_blocked[p] = study_blocked[p] + 1;
                    after_count = queued[p] + (s_valid[p] && s_ready[p]) - (m_valid && m_ready && m_source == p);
                    if (queued[p] > study_peak[p]) study_peak[p] = queued[p];
                    if (after_count > study_peak[p]) study_peak[p] = after_count;
                end
            end
            if (m_valid && m_ready) begin
                p = m_source;
                f = frames[p];
                if (m_data[3:0] == 0) study_first[p][f] = n;
                if (m_last) study_complete[p][f] = n;
                if (n >= study_start && n <= study_end)
                    study_output_beats[p] = study_output_beats[p] + 1;
            end
            if (n >= study_start && n <= study_end) begin
                // Exhaustive precedence: transfer, downstream-not-ready, then
                // local queue/grant classification. READY=0 is availability,
                // not a claim that a valid output necessarily existed.
                if (m_valid && m_ready) category = 0;
                else if (!m_ready) category = 1;
                else if (EXTERNAL) category = 6;
                else if (ref_grant >= 0) category = 2;
                else if (pending && !eligible) category = 3;
                else if (pending) category = 4;
                else category = 5;
                study_categories[category] = study_categories[category] + 1;
            end
        end
    end
endtask

// Static locals also keep Icarus' VPI file/plusarg destinations addressable.
task study;
    integer input_file, frame_file, count_file, rc, configured_ports;
    integer p, b, f, n, category_sum, release_at;
    reg done;
    string plan_path, ready_path, frames_path, counts_path;
    begin
        check(mode == 1, "study requires round robin");
        check($value$plusargs("STUDY_PLAN=%s", plan_path), "missing STUDY_PLAN");
        check($value$plusargs("STUDY_READY=%s", ready_path), "missing STUDY_READY");
        check($value$plusargs("STUDY_FRAMES=%s", frames_path), "missing STUDY_FRAMES");
        check($value$plusargs("STUDY_COUNTS=%s", counts_path), "missing STUDY_COUNTS");
        input_file = $fopen(plan_path, "r");
        check(input_file != 0, "cannot open study release plan");
        rc = $fscanf(input_file, "%d %d %d %d\n", configured_ports, study_start, study_end, study_maxcycles);
        check(rc == 4 && configured_ports == PORTS, "bad study plan header");
        check(study_start > 0 && study_end >= study_start && study_end < study_maxcycles && study_maxcycles < STUDY_MAX_CYCLES,
              "study time bounds exceed storage");
        for (p = 0; p < PORTS; p = p + 1) begin
            rc = $fscanf(input_file, "%d %d\n", study_count[p], study_g[p]);
            check(rc == 2 && study_count[p] >= 0 && study_count[p] <= STUDY_MAX_BEATS && study_count[p] % 16 == 0,
                  "bad study source count");
            for (b = 0; b < study_count[p]; b = b + 1) begin
                rc = $fscanf(input_file, "%d\n", release_at);
                study_release[p][b] = release_at;
                check(rc == 1 && study_release[p][b] > 0 && study_release[p][b] <= study_end, "bad study release");
                if (b > 0) check(study_release[p][b] > study_release[p][b-1], "release times must increase");
            end
            for (f = 0; f < STUDY_MAX_BEATS/16; f = f + 1) begin
                study_offer[p][f] = -1; study_accept[p][f] = -1;
                study_first[p][f] = -1; study_complete[p][f] = -1;
            end
            study_gap[p] = 0; study_input_beats[p] = 0; study_output_beats[p] = 0;
            study_blocked[p] = 0; study_peak[p] = 0;
        end
        $fclose(input_file);
        $readmemh(ready_path, study_ready_plan, 0, study_maxcycles);
        study_active = 0;
        reset_epoch();
        study_epoch = cycle;
        for (p = 0; p < 7; p = p + 1) study_categories[p] = 0;
        study_active = 1;
        done = 0;
        while (!done && cycle-study_epoch < study_maxcycles) begin
            n = cycle - study_epoch + 1;
            check(study_ready_plan[n] === 1'b0 || study_ready_plan[n] === 1'b1, "missing study ready sample");
            m_ready = study_ready_plan[n];
            for (p = 0; p < PORTS; p = p + 1) begin
                s_valid[p] = 0;
                if (issued[p] < study_count[p]) begin
                    s_valid[p] = study_release[p][issued[p]] <= n;
                    s_data[p*DATA_WIDTH +: DATA_WIDTH] = payload(p, issued[p]);
                    s_last[p] = issued[p] % 16 == 15;
                    if (s_valid[p] && issued[p] % 16 == 0 && study_offer[p][issued[p]/16] < 0)
                        study_offer[p][issued[p]/16] = n;
                end
            end
            tick();
            done = n >= study_end && accepted == delivered;
            for (p = 0; p < PORTS; p = p + 1) done = done && issued[p] == study_count[p];
        end
        study_active = 0;
        category_sum = 0;
        for (p = 0; p < 7; p = p + 1) category_sum = category_sum + study_categories[p];
        check(category_sum == study_end-study_start+1, "study cycle categories do not partition window");
        frame_file = $fopen(frames_path, "w"); count_file = $fopen(counts_path, "w");
        check(frame_file != 0 && count_file != 0, "cannot write study CSV");
        $fdisplay(frame_file, "source,frame,generation,first_offer,first_accept,first_output,completion");
        for (p = 0; p < PORTS; p = p + 1)
            for (f = 0; f < study_count[p]/16; f = f + 1)
                $fdisplay(frame_file, "%0d,%0d,%0d,%0d,%0d,%0d,%0d", p, f, study_release[p][f*16],
                          study_offer[p][f], study_accept[p][f], study_first[p][f], study_complete[p][f]);
        $fdisplay(count_file, "scope,source,metric,value");
        $fdisplay(count_file, "total,-1,window_start,%0d", study_start);
        $fdisplay(count_file, "total,-1,window_end,%0d", study_end);
        $fdisplay(count_file, "total,-1,elapsed,%0d", cycle-study_epoch);
        $fdisplay(count_file, "total,-1,transfer,%0d", study_categories[0]);
        $fdisplay(count_file, "total,-1,downstream_not_ready,%0d", study_categories[1]);
        $fdisplay(count_file, "total,-1,source_starvation,%0d", study_categories[2]);
        $fdisplay(count_file, "total,-1,admission_wait,%0d", study_categories[3]);
        $fdisplay(count_file, "total,-1,registered_grant,%0d", study_categories[4]);
        $fdisplay(count_file, "total,-1,empty,%0d", study_categories[5]);
        $fdisplay(count_file, "total,-1,external_unclassified,%0d", study_categories[6]);
        for (p = 0; p < PORTS; p = p + 1) begin
            $fdisplay(count_file, "source,%0d,input_beats,%0d", p, study_input_beats[p]);
            $fdisplay(count_file, "source,%0d,output_beats,%0d", p, study_output_beats[p]);
            $fdisplay(count_file, "source,%0d,input_blocked,%0d", p, study_blocked[p]);
            $fdisplay(count_file, "source,%0d,peak_outstanding,%0d", p, study_peak[p]);
        end
        $fclose(frame_file); $fclose(count_file);
        check(done, "study reached watchdog with unfinished frames; inspect frame CSV");
        check(frame_beat == 0, "study ended inside a frame");
        $display("STUDY cycles=%0d window=%0d transfer=%0d source_starvation=%0d admission_wait=%0d external=%0d",
                 cycle-study_epoch, category_sum, study_categories[0], study_categories[2], study_categories[3], EXTERNAL);
    end
endtask
