`timescale 1ns/1ps
// Portable on-chip workload/checker. A board integration supplies a clock,
// synchronous reset, and synchronized controls (for example through VIO).
// load_mode is latched on reset: 0=single, 1=saturated, 2=periodic backpressure.
// Hold run low to finish offered frames and drain. Read counters when done.
module stream_selftest (
    input  wire         clk,
    input  wire         rst,
    input  wire         mode_rr,
    input  wire [1:0]   load_mode,
    input  wire         run,
    input  wire         inject_error,
    output wire         done,
    output reg  [127:0] input_words,
    output wire [31:0]  output_words,
    output wire [127:0] output_frames,
    output wire [31:0]  error_count,
    output wire [3:0]   protocol_error,
    output reg  [31:0]  elapsed_cycles,
    output reg  [31:0]  backpressure_cycles,
    output reg  [127:0] source_stall_cycles,
    output reg  [27:0]  fifo_peak
);
    reg [1:0] load_q;
    reg [4:0] phase;
    reg inject_q, inject_pending;
    wire [127:0] s_data;
    wire [3:0] s_last, s_valid, s_ready;
    wire [31:0] m_data;
    wire [1:0] m_source;
    wire m_last, m_valid, m_ready;
    wire [27:0] fifo_level;
    wire transfer = m_valid && m_ready;
    integer i;
    genvar g;

    assign m_ready = (load_q != 2) || (phase >= 8);
    assign done = !run && (s_valid == 0) && (fifo_level == 0) && !m_valid;

    generate for (g = 0; g < 4; g = g + 1) begin : sources
        traffic_source #(.SOURCE_ID(g)) source (
            .clk(clk), .rst(rst), .run(run && ((load_q != 0) || (g == 0))),
            .data(s_data[g*32 +: 32]), .last(s_last[g]),
            .valid(s_valid[g]), .ready(s_ready[g])
        );
    end endgenerate

    stream_arbiter arbiter (
        .clk(clk), .rst(rst), .mode_rr(mode_rr),
        .s_data(s_data), .s_last(s_last), .s_valid(s_valid), .s_ready(s_ready),
        .m_data(m_data), .m_last(m_last), .m_valid(m_valid), .m_ready(m_ready),
        .m_source(m_source), .protocol_error(protocol_error), .fifo_level(fifo_level)
    );
    sink_checker sink_monitor (
        .clk(clk), .rst(rst), .data(m_data ^ {31'd0, inject_pending}),
        .last(m_last), .source(m_source), .valid(m_valid), .ready(m_ready),
        .words(output_words), .frames(output_frames), .errors(error_count)
    );

    always @(posedge clk) begin
        if (rst) begin
            load_q <= load_mode;
            phase <= 0;
            inject_q <= 0;
            inject_pending <= 0;
            input_words <= 0;
            elapsed_cycles <= 0;
            backpressure_cycles <= 0;
            source_stall_cycles <= 0;
            fifo_peak <= 0;
        end else begin
            phase <= phase + 1'b1;
            inject_q <= inject_error;
            // A rising edge queues one corruption; requests coalesce while pending.
            if (inject_pending && transfer)
                inject_pending <= 0;
            else if (inject_error && !inject_q)
                inject_pending <= 1;
            if (!done)
                elapsed_cycles <= elapsed_cycles + 1'b1;
            if (m_valid && !m_ready)
                backpressure_cycles <= backpressure_cycles + 1'b1;
            for (i = 0; i < 4; i = i + 1) begin
                if (s_valid[i] && s_ready[i])
                    input_words[i*32 +: 32] <= input_words[i*32 +: 32] + 1'b1;
                if (s_valid[i] && !s_ready[i])
                    source_stall_cycles[i*32 +: 32] <= source_stall_cycles[i*32 +: 32] + 1'b1;
                if (fifo_level[i*7 +: 7] > fifo_peak[i*7 +: 7])
                    fifo_peak[i*7 +: 7] <= fifo_level[i*7 +: 7];
            end
        end
    end
endmodule
