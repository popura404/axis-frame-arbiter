`timescale 1ns/1ps
module tb_stream_selftest;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, mode_rr = 0, run = 0, inject_error = 0;
    reg [1:0] load_mode = 0;
    wire done;
    wire [127:0] input_words, output_frames, source_stall_cycles;
    wire [31:0] output_words, error_count, elapsed_cycles, backpressure_cycles;
    wire [3:0] protocol_error;
    wire [27:0] fifo_peak;
    reg [3:0] stalled = 0;
    reg [127:0] previous_data;
    reg [3:0] previous_last;
    integer mode, load, i, timeout_cycles;
    reg [31:0] total;

    stream_selftest dut (.*);

    // In particular, run going low must not withdraw a stalled offered beat.
    always @(posedge clk) begin
        if (rst) begin
            stalled = 0;
        end else begin
            for (integer s = 0; s < 4; s = s + 1)
                if (stalled[s] && (!dut.s_valid[s] ||
                    dut.s_data[s*32 +: 32] !== previous_data[s*32 +: 32] ||
                    dut.s_last[s] !== previous_last[s]))
                    $fatal(1, "selftest source changed a stalled beat, source=%0d", s);
            stalled = dut.s_valid & ~dut.s_ready;
            previous_data = dut.s_data;
            previous_last = dut.s_last;
        end
    end

    task reset_epoch;
        begin
            @(negedge clk);
            rst = 1;
            run = 0;
            inject_error = 0;
            repeat (3) @(negedge clk);
            rst = 0;
            #1;
            if (!done || input_words != 0 || output_words != 0 ||
                output_frames != 0 || error_count != 0 || protocol_error != 0 ||
                elapsed_cycles != 0 || source_stall_cycles != 0 || fifo_peak != 0 ||
                backpressure_cycles != 0)
                $fatal(1, "selftest reset did not clear the epoch");
        end
    endtask

    task stop_and_check(input integer expected_errors);
        begin
            @(negedge clk);
            run = 0;
            timeout_cycles = 0;
            while (!done && timeout_cycles < 10000) begin
                @(negedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (!done) $fatal(1, "selftest drain timeout");
            total = 0;
            for (i = 0; i < 4; i = i + 1) begin
                total = total + input_words[i*32 +: 32];
                if (input_words[i*32 +: 32] != 16 * output_frames[i*32 +: 32])
                    $fatal(1, "selftest incomplete frame, source=%0d", i);
                if (load_mode == 0 && i != 0 && input_words[i*32 +: 32] != 0)
                    $fatal(1, "selftest single-source load enabled source=%0d", i);
                if (load_mode != 0 && input_words[i*32 +: 32] == 0)
                    $fatal(1, "selftest did not exercise source=%0d", i);
            end
            if (total == 0 || total != output_words ||
                error_count != expected_errors || protocol_error != 0)
                $fatal(1, "selftest totals/errors: in=%0d out=%0d errors=%0d expected=%0d protocol=%h",
                    total, output_words, error_count, expected_errors, protocol_error);
            if (load_mode == 2 && backpressure_cycles == 0)
                $fatal(1, "selftest periodic backpressure was not exercised");
            $display("SELFTEST mode=%0d load=%0d words=%0d cycles=%0d errors=%0d backpressure=%0d",
                mode_rr, load_mode, output_words, elapsed_cycles, error_count, backpressure_cycles);
        end
    endtask

    initial begin
        for (mode = 0; mode < 2; mode = mode + 1) begin
            for (load = 0; load < 3; load = load + 1) begin
                mode_rr = mode;
                load_mode = load;
                reset_epoch();
                run = 1;
                repeat (1003) @(negedge clk);
                stop_and_check(0);
            end
        end
        mode_rr = 1;
        load_mode = 2;
        reset_epoch();
        run = 1;
        repeat (101) @(negedge clk);
        inject_error = 1;
        // Holding the command high must still produce exactly one corruption.
        repeat (20) @(negedge clk);
        inject_error = 0;
        repeat (151) @(negedge clk);
        stop_and_check(1);
        $display("EXPECTED_ERROR: one injected payload error detected");

        reset_epoch();
        run = 1;
        repeat (81) @(negedge clk);
        reset_epoch();
        run = 1;
        repeat (131) @(negedge clk);
        stop_and_check(0);
        $display("PASS tb_stream_selftest");
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "selftest global timeout");
    end
endmodule
