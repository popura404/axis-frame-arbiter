`timescale 1ns/1ps
// 单路输入封装：将 DATA/LAST 一起缓存，协议监测独立于存储通路。
module stream_fifo (
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] s_data,
    input  wire        s_last,
    input  wire        s_valid,
    output wire        s_ready,

    output wire [31:0] m_data,
    output wire        m_last,
    output wire        m_valid,
    input  wire        m_ready,

    output wire [6:0]  level,
    output wire        next_valid,
    output wire        protocol_error
);
    sync_fifo #(
        .WIDTH (33),
        .DEPTH (64)
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

    stream_protocol_checker protocol_monitor (
        .clk            (clk),
        .rst            (rst),
        .data           (s_data),
        .last           (s_last),
        .valid          (s_valid),
        .ready          (s_ready),
        .protocol_error (protocol_error)
    );
endmodule
