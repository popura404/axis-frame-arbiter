`timescale 1ns/1ps
// 单路输入封装：将 DATA/LAST 一起缓存，协议监测独立于存储通路。
module stream_fifo #(
    parameter integer DATA_WIDTH = 32,
    parameter integer FIFO_DEPTH = 64
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [DATA_WIDTH-1:0] s_data,
    input  wire        s_last,
    input  wire        s_valid,
    output wire        s_ready,

    output wire [DATA_WIDTH-1:0] m_data,
    output wire        m_last,
    output wire        m_valid,
    input  wire        m_ready,

    output wire [$clog2(FIFO_DEPTH):0] level,
    output wire        next_valid,
    output wire        protocol_error
);
    sync_fifo #(
        .WIDTH (DATA_WIDTH + 1),
        .DEPTH (FIFO_DEPTH)
    ) fifo (
        .clk        (clk),
        .rst        (rst),
        .s_data     ({s_last, s_data}),
        .s_valid    (s_valid),
        .s_ready    (s_ready),
        .m_data     ({m_last, m_data}),
        .m_valid    (m_valid),
        .m_ready    (m_ready),
        .level      (level),
        .next_valid (next_valid)
    );

    stream_protocol_checker #(
        .DATA_WIDTH (DATA_WIDTH)
    ) protocol_monitor (
        .clk            (clk),
        .rst            (rst),
        .data           (s_data),
        .last           (s_last),
        .valid          (s_valid),
        .ready          (s_ready),
        .protocol_error (protocol_error)
    );
endmodule
