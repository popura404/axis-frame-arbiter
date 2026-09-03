`timescale 1ns/1ps
// N 路独立 AXI4-Stream 的展平接口，固定 16 拍、每拍全部字节有效。
// TKEEP/TSTRB 省略；输出 TID 由输入端口号生成，不接收输入 TID。
// aresetn 与 aclk 同步，至少跨一个上升沿；本层不引入额外流水延迟。
module axis_stream_arbiter #(
    parameter integer PORTS = 4,
    parameter integer DATA_WIDTH = 32,
    parameter integer FIFO_DEPTH = 64,
    parameter [PORTS*5-1:0] ADMISSION_LEVELS = {PORTS{5'd1}}
) (
    input  wire                                  aclk,
    input  wire                                  aresetn,
    input  wire                                  mode_rr,

    input  wire [PORTS*DATA_WIDTH-1:0]             s_axis_tdata,
    input  wire [PORTS-1:0]                        s_axis_tlast,
    input  wire [PORTS-1:0]                        s_axis_tvalid,
    output wire [PORTS-1:0]                        s_axis_tready,

    output wire [DATA_WIDTH-1:0]                   m_axis_tdata,
    output wire                                  m_axis_tlast,
    output wire                                  m_axis_tvalid,
    input  wire                                  m_axis_tready,
    output wire [$clog2(PORTS)-1:0]               m_axis_tid,

    output wire [PORTS-1:0]                        protocol_error,
    output wire [PORTS*($clog2(FIFO_DEPTH)+1)-1:0]  fifo_level
);
    // 复用同一数据通路、调度和参数检查；每个输入端口代表一条流。
    stream_arbiter #(
        .PORTS      (PORTS),
        .DATA_WIDTH (DATA_WIDTH),
        .FIFO_DEPTH (FIFO_DEPTH),
        .ADMISSION_LEVELS (ADMISSION_LEVELS)
    ) core (
        .clk            (aclk),
        .rst            (!aresetn),
        .mode_rr        (mode_rr),
        .s_data         (s_axis_tdata),
        .s_last         (s_axis_tlast),
        .s_valid        (s_axis_tvalid),
        .s_ready        (s_axis_tready),
        .m_data         (m_axis_tdata),
        .m_last         (m_axis_tlast),
        .m_valid        (m_axis_tvalid),
        .m_ready        (m_axis_tready),
        .m_source       (m_axis_tid),
        .protocol_error (protocol_error),
        .fifo_level     (fifo_level)
    );
endmodule
