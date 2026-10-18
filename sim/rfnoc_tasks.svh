// Real UHD source path; this include extends the primary handshake scoreboard.
// The host is a format-checking ACK model, not a model of host software timing.
reg rf_radio_clk = 0, rf_radio_rst = 1;
reg [63:0] rf_radio_time = 0;
reg [PORTS-1:0] rf_sample_valid = 0;
wire [PORTS-1:0] rf_sample_ready, rf_running, rf_request, rf_ack;
wire [PORTS*64-1:0] rf_request_time;
wire [PORTS*32-1:0] rf_data;
wire [PORTS-1:0] rf_last, rf_valid, rf_ready;
reg [PORTS*32-1:0] rf_ack_data = 0;
reg [PORTS-1:0] rf_ack_last = 0, rf_ack_valid = 0;
wire [PORTS-1:0] rf_ack_ready;
reg [31:0] rf_ack_words [0:PORTS-1][0:2];
reg [63:0] rf_ack_identity [0:PORTS-1];
reg [31:0] rf_output_words [0:5];
reg [PORTS-1:0] rf_ack_pending = 0, rf_seen_alert = 0;
reg rf_corrupt_tail = 0;
reg [PORTS*32-1:0] rf_manual_data = 0;
reg [PORTS-1:0] rf_manual_last = 0, rf_manual_valid = 0;
integer rf_ack_index [0:PORTS-1], rf_ack_due [0:PORTS-1];
integer rf_input_index [0:PORTS-1], rf_input_frames [0:PORTS-1];
integer rf_scheduled [0:PORTS-1];
integer rf_consumer_sequence [0:PORTS-1];
integer rf_radio_cycle = 0, rf_epoch = 0, rf_control_cycle = 0;
integer rf_generated = 0, rf_fifo_accepted = 0, rf_fifo_dropped = 0;
integer rf_requests = 0, rf_acks = 0, rf_completed = 0, rf_faults = 0;
integer rf_output_index = 0, rf_output_source = 0;
integer rf_log = 0, rf_phase_ps = 0;
string rf_scenario = "sparse", rf_trace_path;

function automatic longint rf_time_ps();
    rf_time_ps = $rtoi($realtime * 1000.0);
endfunction

task automatic rf_record(input string kind, input integer lane,
                         input reg [63:0] identity, input integer beat,
                         input reg [31:0] data, input integer last,
                         input integer detail);
    if (rf_log) $fdisplay(rf_log, "%0d,%s,%0d,%0d,%0d,%08x,%0d,%0d",
        rf_time_ps(), kind, lane, identity, beat, data, last, detail);
endtask

function automatic integer rf_count(input integer lane);
    if (rf_epoch) rf_count = 8;
    else if (rf_scenario == "sparse") rf_count = lane == 0 ? 8 : 0;
    else if (rf_scenario == "overload") rf_count = 80;
    else if (rf_scenario == "lost_tail") rf_count = 64;
    else rf_count = 24;
endfunction

function automatic integer rf_period();
    if (rf_epoch) rf_period = 16;
    else if (rf_scenario == "sparse") rf_period = 80;
    else if (rf_scenario == "overload" || rf_scenario == "lost_tail") rf_period = 4;
    else rf_period = 8;
endfunction

initial if (RFNOC) begin
    if ($value$plusargs("RADIO_PHASE_PS=%d", rf_phase_ps)) begin end
    #(rf_phase_ps / 1000.0);
    forever #6.25 rf_radio_clk = ~rf_radio_clk; // 80 MHz; control clock is 100 MHz.
end

genvar rf_lane;
generate if (RFNOC) begin : rfnoc_sources
    for (rf_lane = 0; rf_lane < PORTS; rf_lane = rf_lane + 1) begin : lanes
        rfnoc_source #(.SOURCE_ID(rf_lane)) source (
            .radio_clk(rf_radio_clk), .ctrl_clk(clk),
            .radio_rst(rf_radio_rst), .ctrl_rst(rst),
            .sample_valid(rf_sample_valid[rf_lane]), .sample_ready(rf_sample_ready[rf_lane]),
            .radio_strobe(1'b1), .radio_time(rf_radio_time), .radio_running(rf_running[rf_lane]),
            .request_valid(rf_request[rf_lane]), .request_ack(rf_ack[rf_lane]),
            .request_time(rf_request_time[rf_lane*64 +: 64]),
            .m_data(rf_data[rf_lane*32 +: 32]), .m_last(rf_last[rf_lane]),
            .m_valid(rf_valid[rf_lane]), .m_ready(rf_ready[rf_lane]),
            .s_data(rf_ack_data[rf_lane*32 +: 32]), .s_last(rf_ack_last[rf_lane]),
            .s_valid(rf_ack_valid[rf_lane]), .s_ready(rf_ack_ready[rf_lane])
        );
        assign rf_ready[rf_lane] = s_ready[rf_lane] && !rf_diagnostic;
        // Observe an actual source FIFO interface, not its implementation state.
        always @(posedge rf_radio_clk) if (!rf_radio_rst && source.radio.error_fifo.i_tvalid) begin
            if (source.radio.error_fifo.i_tready) begin
                rf_fifo_accepted = rf_fifo_accepted + 1;
                rf_record("SOURCE_ACCEPT", rf_lane, source.radio.error_fifo.i_tdata[65:2], 0, 0, 0, 0);
            end else begin
                rf_fifo_dropped = rf_fifo_dropped + 1;
                rf_record("SOURCE_DROP", rf_lane, source.radio.error_fifo.i_tdata[65:2], 0, 0, 0, 0);
            end
        end
    end
    always @* begin
        s_data = rf_diagnostic ? rf_manual_data : rf_data;
        s_valid = rf_diagnostic ? rf_manual_valid : rf_valid;
        s_last = rf_diagnostic ? rf_manual_last : rf_last;
        s_keep = {PORTS*KEEP_WIDTH{1'b1}};
        // Fault after the preserved CDC, not a claim of a normal RFNoC event.
        if (rf_corrupt_tail && !rf_diagnostic)
            s_last[0] = 0;
    end
    integer rf_comb_lane;
    // All consumer-driven signals change on the falling edge, never in the
    // same active queue as the source's rising-edge handshake evaluation.
    always @(negedge clk) begin
        rf_corrupt_tail <= rf_scenario == "lost_tail" && !rf_epoch && rf_input_frames[0] == 2;
        for (rf_comb_lane = 0; rf_comb_lane < PORTS; rf_comb_lane = rf_comb_lane+1) begin
            rf_ack_valid[rf_comb_lane] <= !rst && rf_ack_pending[rf_comb_lane] && cycle >= rf_ack_due[rf_comb_lane];
            rf_ack_last[rf_comb_lane] <= rf_ack_index[rf_comb_lane] == 2;
            rf_ack_data[rf_comb_lane*32 +: 32] <= rf_ack_words[rf_comb_lane][rf_ack_index[rf_comb_lane]];
        end
    end
end endgenerate

integer rf_radio_lane;
always @(posedge rf_radio_clk) if (RFNOC) begin
    rf_radio_time <= rf_radio_time + 1;
    if (rf_radio_rst) begin
        rf_sample_valid <= 0;
        rf_radio_cycle = 0;
        for (rf_radio_lane = 0; rf_radio_lane < PORTS; rf_radio_lane=rf_radio_lane+1)
            rf_scheduled[rf_radio_lane] = 0;
    end else begin
        rf_radio_cycle = rf_radio_cycle + 1;
        for (rf_radio_lane = 0; rf_radio_lane < PORTS; rf_radio_lane=rf_radio_lane+1) begin
            if (rf_running[rf_radio_lane] && !rf_sample_valid[rf_radio_lane]) begin
                rf_generated = rf_generated+1;
                rf_record("GENERATE", rf_radio_lane, rf_radio_time, 0, 1, 0, rf_epoch);
            end
            if (rf_request[rf_radio_lane]) begin
                rf_requests = rf_requests+1;
                rf_record("REQUEST", rf_radio_lane, rf_request_time[rf_radio_lane*64 +: 64], 0, 0, 0, rf_epoch);
            end
            if (rf_ack[rf_radio_lane]) begin
                rf_acks = rf_acks+1;
                rf_record("ACK", rf_radio_lane, rf_request_time[rf_radio_lane*64 +: 64], 0, 0, 0, rf_epoch);
            end
            // Input sample stimulus follows a fixed release schedule. Keep a
            // full low-VALID edge after each accepted one-sample packet, so
            // the radio itself generates the missing-next-sample event.
            if (rf_sample_valid[rf_radio_lane] && rf_sample_ready[rf_radio_lane]) begin
                rf_sample_valid[rf_radio_lane] <= 0;
                rf_scheduled[rf_radio_lane] = rf_scheduled[rf_radio_lane]+1;
            end else if (!rf_sample_valid[rf_radio_lane] &&
                rf_scheduled[rf_radio_lane] < rf_count(rf_radio_lane) &&
                rf_radio_cycle >= 20 + rf_scheduled[rf_radio_lane]*rf_period())
                rf_sample_valid[rf_radio_lane] <= 1;
        end
    end
end

task automatic rfnoc_sample;
    integer lane;
    reg [63:0] identity;
    begin
        if (rf_scenario=="lost_tail" && !rf_epoch && rf_faults>0)
            check((protocol_error & 4'b1110)==0,"unplanned healthy-source error");
        else check(protocol_error==0,"error before injection or after recovery");
        for (lane=0; lane<PORTS; lane=lane+1) begin
            if (protocol_error[lane] && !rf_seen_alert[lane]) begin
                rf_seen_alert[lane] = 1;
                rf_record("ALERT", lane, 0, 0, 0, 0, rf_epoch);
            end
            if (rf_ack_valid[lane] && rf_ack_ready[lane]) begin
                rf_record("ACK_SEND", lane, rf_ack_identity[lane], rf_ack_index[lane],
                          rf_ack_data[lane*32 +: 32], rf_ack_last[lane], rf_epoch);
                if (rf_ack_index[lane] == 2) begin
                    rf_ack_pending[lane] = 0;
                    rf_ack_index[lane] = 0;
                end else rf_ack_index[lane] = rf_ack_index[lane]+1;
            end
            if (s_valid[lane] && s_ready[lane]) begin
                rf_record("IN", lane, rf_input_frames[lane], rf_input_index[lane],
                          s_data[lane*32 +: 32], s_last[lane], rf_last[lane]);
                if (rf_last[lane]) begin
                    check(rf_input_index[lane] == 5, "real RFNoC producer record was not six words");
                    if (!s_last[lane]) begin
                        rf_faults = rf_faults+1;
                        rf_record("FAULT", lane, rf_input_frames[lane], 5, 0, 0, rf_epoch);
                    end
                    rf_input_frames[lane] = rf_input_frames[lane]+1;
                    rf_input_index[lane] = 0;
                end else rf_input_index[lane] = rf_input_index[lane]+1;
            end
        end
        if (m_valid && m_ready) begin
            if (rf_output_index == 0) rf_output_source = m_source;
            check(m_source == rf_output_source && rf_output_index < 6, "RFNoC output mixed or overlong record");
            rf_output_words[rf_output_index] = m_data;
            rf_record("OUT", m_source, 0, rf_output_index, m_data, m_last, rf_epoch);
            if (m_last) begin
                check(rf_output_index == 5, "RFNoC consumer rejected short record");
                check(!rf_output_words[0][15] && rf_output_words[0][14] &&
                      rf_output_words[0][13:10] == 1, "RFNoC request header mismatch");
                check(rf_output_words[1][9:0] == m_source, "RFNoC request source port mismatch");
                check(rf_output_words[1][27:20] == rf_consumer_sequence[m_source]%256,
                      "RFNoC request sequence mismatch");
                rf_consumer_sequence[m_source] = rf_consumer_sequence[m_source]+1;
                check(rf_output_words[4][31:30] == 0 && rf_output_words[4][27:24] == 1 &&
                      rf_output_words[4][23:20] == 15 &&
                      rf_output_words[5] == 1, "RFNoC consumer rejected operation or underrun code");
                identity = {rf_output_words[3],rf_output_words[2]};
                rf_record("COMPLETE", m_source, identity, 5, m_data, 1, rf_epoch);
                rf_completed = rf_completed+1;
                check(!rf_ack_pending[m_source], "more than one outstanding event per real source");
                // Legal three-word write ACK: no timestamp/data, echoed seq/op.
                rf_ack_words[m_source][0] = 32'h00008000 | m_source;
                rf_ack_words[m_source][1] = rf_output_words[1] & 32'h0ff00000;
                rf_ack_words[m_source][2] = rf_output_words[4];
                rf_ack_index[m_source] = 0;
                rf_ack_identity[m_source] = identity;
                // Drive VALID on the falling edge before C+20, so the first
                // ACK transfer is eligible exactly 20 control clocks later.
                rf_ack_due[m_source] = cycle + 19;
                rf_ack_pending[m_source] = 1;
                rf_output_index = 0;
            end else rf_output_index = rf_output_index+1;
        end
    end
endtask

// One regression for the added baseline adapter, through the same scoreboard.
// These artificial 7/17-word records are not RFNoC application traffic.
task automatic rf_put(input integer lane, input reg [31:0] data, input bit last);
    reg transfer;
    begin
        rf_manual_data[lane*32 +: 32] = data;
        rf_manual_last[lane] = last;
        rf_manual_valid[lane] = 1;
        do begin
            @(posedge clk);
            transfer = s_ready[lane];
            sample();
            #1;
            @(negedge clk);
        end while (!transfer);
        rf_manual_valid[lane] = 0;
    end
endtask

task automatic rf_baseline_diagnostic;
    integer n;
    begin
        rf_diagnostic = 1;
        expected_error = 1;
        rst = 1;
        rf_radio_rst = 1;
        rf_ack_pending = 0;
        m_ready = 0;
        repeat(10) tick();
        rst = 0;
        for(n=0;n<6;n=n+1) rf_put(0,32'ha000+n,n==5);
        check(protocol_error==0,"baseline rejected exact-M legal frame");
        rf_put(1,32'hb000,0);rf_put(1,32'hb001,1);
        for(n=0;n<6;n=n+1) rf_put(0,32'he000+n,0);
        check(protocol_error==1,"baseline failed same-M detection");
        rf_put(0,32'he006,1);
        m_ready=1;
        rf_put(0,32'hc000,0);rf_put(0,32'hc001,1);
        repeat(50) tick();
        check(delivered==10,"baseline failed old/healthy/post-error frame delivery");
        m_ready=0;
        rf_put(0,32'hd000,0);rf_put(0,32'hd001,1);
        for(n=0;n<17;n=n+1) rf_put(0,32'he100+n,n==16);
        m_ready=1;rf_put(0,32'hf000,1);
        repeat(50) tick();
        check(delivered==13 && queued[0]==0 && queued[1]==0 && protocol_error==1,
              "baseline oversize recovery or sticky alert failed");
        rst=1;repeat(4) tick();
        check(protocol_error==0,"baseline reset failed to clear alert");
        $display("PASS bounded baseline diagnostic exact6 bad7 bad17 old/healthy frames recovery sticky/reset");
    end
endtask

task automatic rf_reset;
    integer lane;
    begin
        rf_record("RESET_ASSERT", -1, 0, 0, 0, 0, rf_epoch);
        rst = 1;
        rf_radio_rst = 1;
        m_ready = 0;
        rf_ack_pending = 0;
        rf_seen_alert = 0;
        rf_output_index = 0;
        for (lane=0; lane<PORTS; lane=lane+1) begin
            rf_ack_index[lane] = 0;
            rf_ack_due[lane] = 0;
            rf_ack_identity[lane] = 0;
            rf_consumer_sequence[lane] = 0;
            rf_input_index[lane] = 0;
            rf_input_frames[lane] = 0;
            rf_ack_words[lane][0] = 0;
            rf_ack_words[lane][1] = 0;
            rf_ack_words[lane][2] = 0;
        end
        repeat (10) tick();
        rst = 0;
        rf_radio_rst = 0;
        rf_record("RESET_RELEASE", -1, 0, 0, 0, 0, rf_epoch);
    end
endtask

task automatic rfnoc_tests;
    integer j;
    begin
        check(RFNOC && PORTS==4 && DATA_WIDTH==32 && FIFO_DEPTH==16 &&
              PACKET_MODE && MAX_FRAME_BEATS==6 && !KEEP_ENABLE && mode==1,
              "RFNoC comparison requires the preregistered 4/32/16 M6 RR configuration");
        if ($value$plusargs("RF_SCENARIO=%s", rf_scenario)) begin end
        check(rf_scenario=="sparse" || rf_scenario=="contended" || rf_scenario=="backpressure" ||
              rf_scenario=="overload" || rf_scenario=="lost_tail", "unknown RFNoC scenario");
        check(EXTERNAL != 2 || rf_scenario != "lost_tail",
              "rr_only has no post-gate fault containment contract; compare legal traffic only");
        check($value$plusargs("RF_TRACE=%s", rf_trace_path), "RF_TRACE is required");
        rf_log = $fopen(rf_trace_path,"w");
        check(rf_log != 0, "cannot open RF_TRACE");
        $fdisplay(rf_log,"time_ps,kind,lane,identity,beat,data,last,detail");
        mode_rr = 1;
        expected_error = rf_scenario=="lost_tail";
        rf_reset();
        // Fixed observation horizon. Do not stop sooner for a faster candidate.
        for (rf_control_cycle=0; rf_control_cycle<12000; rf_control_cycle=rf_control_cycle+1) begin
            if (rf_scenario=="lost_tail" && rf_control_cycle==400) begin
                rf_epoch=1;
                rf_reset();
            end
            m_ready = !(rf_scenario=="backpressure" && rf_control_cycle>=80 && rf_control_cycle<180) &&
                      !(rf_scenario=="lost_tail" && rf_control_cycle>=320 && rf_control_cycle<400);
            tick();
        end
        if (rf_scenario != "lost_tail") begin
            check(rf_generated == rf_fifo_accepted+rf_fifo_dropped, "source FIFO accounting mismatch");
            check(rf_completed == rf_acks, "delivered records did not receive real reverse-CDC ACKs");
            check(rf_fifo_accepted == rf_completed, "source-accepted events failed to drain");
            if (rf_scenario != "overload") check(rf_fifo_dropped==0,"unexpected source event loss");
        end else check(rf_faults==1,"lost-tail fault was not injected exactly once");
        for (j=0;j<PORTS;j=j+1) check(queued[j]==0,"candidate did not drain after final epoch");
        rf_record("END",-1,0,0,0,0,rf_epoch);
        $fclose(rf_log);
        rf_log=0;
        tests=tests+1;
        $display("RFNOC_PASS scenario=%s external=%0d generated=%0d source_accept=%0d source_drop=%0d completed=%0d ack=%0d faults=%0d phase_ps=%0d",
            rf_scenario,EXTERNAL,rf_generated,rf_fifo_accepted,rf_fifo_dropped,rf_completed,rf_acks,rf_faults,rf_phase_ps);
        if (EXTERNAL == 1 && rf_scenario=="sparse" && rf_phase_ps==0) rf_baseline_diagnostic();
    end
endtask
