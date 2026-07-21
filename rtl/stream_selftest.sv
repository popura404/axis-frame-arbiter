`timescale 1ns/1ps
// 片内自测顶层：连接负载控制、四路数据源、仲裁器、接收检查与统计。
// 外部提供同钟控制和同步复位；run 拉低后完成已发起帧并排空。
module stream_selftest (
    input  wire         clk,
    input  wire         rst,
    input  wire         mode_rr,
    input  wire [1:0]   load_mode,
    input  wire         run,
    input  wire         inject_error,
    output wire         done,
    output wire [127:0] input_words,
    output wire [31:0]  output_words,
    output wire [127:0] output_frames,
    output wire [31:0]  error_count,
    output wire [3:0]   protocol_error,
    output wire [31:0]  elapsed_cycles,
    output wire [31:0]  backpressure_cycles,
    output wire [127:0] source_stall_cycles,
    output wire [27:0]  fifo_peak
);
    // 数据源 -> 仲裁器。
    wire [3:0]   source_run;
    wire [127:0] s_data;
    wire [3:0]   s_last;
    wire [3:0]   s_valid;
    wire [3:0]   s_ready;

    // 仲裁器 -> 检查器；checked_data 仅供自测注错使用。
    wire [31:0] m_data;
    wire [1:0]  m_source;
    wire        m_last;
    wire        m_valid;
    wire        m_ready;
    wire [27:0] fifo_level;
    wire [31:0] checked_data;

    selftest_control control (
        .clk          (clk),
        .rst          (rst),
        .load_mode    (load_mode),
        .run          (run),
        .inject_error (inject_error),
        .s_valid      (s_valid),
        .fifo_level   (fifo_level),
        .m_data       (m_data),
        .m_valid      (m_valid),
        .source_run   (source_run),
        .m_ready      (m_ready),
        .checked_data (checked_data),
        .done         (done)
    );

    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : sources
            traffic_source #(
                .SOURCE_ID (lane)
            ) source (
                .clk   (clk),
                .rst   (rst),
                .run   (source_run[lane]),
                .data  (s_data[lane*32 +: 32]),
                .last  (s_last[lane]),
                .valid (s_valid[lane]),
                .ready (s_ready[lane])
            );
        end
    endgenerate

    stream_arbiter arbiter (
        .clk            (clk),
        .rst            (rst),
        .mode_rr        (mode_rr),
        .s_data         (s_data),
        .s_last         (s_last),
        .s_valid        (s_valid),
        .s_ready        (s_ready),
        .m_data         (m_data),
        .m_last         (m_last),
        .m_valid        (m_valid),
        .m_ready        (m_ready),
        .m_source       (m_source),
        .protocol_error (protocol_error),
        .fifo_level     (fifo_level)
    );

    sink_checker sink_monitor (
        .clk    (clk),
        .rst    (rst),
        .data   (checked_data),
        .last   (m_last),
        .source (m_source),
        .valid  (m_valid),
        .ready  (m_ready),
        .words  (output_words),
        .frames (output_frames),
        .errors (error_count)
    );

    perf_counters counters (
        .clk                 (clk),
        .rst                 (rst),
        .done                (done),
        .s_valid             (s_valid),
        .s_ready             (s_ready),
        .m_valid             (m_valid),
        .m_ready             (m_ready),
        .fifo_level          (fifo_level),
        .input_words         (input_words),
        .elapsed_cycles      (elapsed_cycles),
        .backpressure_cycles (backpressure_cycles),
        .source_stall_cycles (source_stall_cycles),
        .fifo_peak           (fifo_peak)
    );
endmodule
