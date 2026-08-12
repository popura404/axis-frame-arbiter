`timescale 1ns/1ps
// 功能顶层：多路输入缓存 -> 帧级授权 -> 一路输出。
// 第 i 路数据位于 s_data[i*DATA_WIDTH +: DATA_WIDTH]，每帧固定 16 拍。
module stream_arbiter #(
    parameter integer PORTS = 4,
    parameter integer DATA_WIDTH = 32,
    parameter integer FIFO_DEPTH = 64
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         mode_rr,

    input  wire [PORTS*DATA_WIDTH-1:0] s_data,
    input  wire [PORTS-1:0] s_last,
    input  wire [PORTS-1:0] s_valid,
    output wire [PORTS-1:0] s_ready,

    output wire [DATA_WIDTH-1:0] m_data,
    output wire        m_last,
    output wire        m_valid,
    input  wire        m_ready,
    output wire [$clog2(PORTS)-1:0] m_source,

    output wire [PORTS-1:0] protocol_error,
    output wire [PORTS*($clog2(FIFO_DEPTH)+1)-1:0] fifo_level
);
    localparam integer LEVEL_WIDTH = $clog2(FIFO_DEPTH) + 1;
    wire [PORTS*DATA_WIDTH-1:0] head_data;
    wire [PORTS-1:0] head_last;
    wire [PORTS-1:0] head_valid;
    wire [PORTS-1:0] head_valid_next;
    wire [PORTS-1:0] head_ready;
    wire grant_active;
    wire frame_done;

    // 1. 每路独立缓存，同时监测输入帧格式与握手协议。
    genvar lane;
    generate
        // 非法配置在展开阶段失败；合法配置不会生成此未定义模块。
        if ((PORTS != 2 && PORTS != 4 && PORTS != 8) ||
            (DATA_WIDTH != 32 && DATA_WIDTH != 64) ||
            (FIFO_DEPTH != 16 && FIFO_DEPTH != 64)) begin : unsupported_configuration
            STREAM_ARBITER_UNSUPPORTED_PARAMETERS invalid_configuration ();
        end
        for (lane = 0; lane < PORTS; lane = lane + 1) begin : inputs
            stream_fifo #(
                .DATA_WIDTH (DATA_WIDTH),
                .FIFO_DEPTH (FIFO_DEPTH)
            ) fifo (
                .clk            (clk),
                .rst            (rst),
                .s_data         (s_data[lane*DATA_WIDTH +: DATA_WIDTH]),
                .s_last         (s_last[lane]),
                .s_valid        (s_valid[lane]),
                .s_ready        (s_ready[lane]),
                .m_data         (head_data[lane*DATA_WIDTH +: DATA_WIDTH]),
                .m_last         (head_last[lane]),
                .m_valid        (head_valid[lane]),
                .m_ready        (head_ready[lane]),
                .level          (fifo_level[lane*LEVEL_WIDTH +: LEVEL_WIDTH]),
                .next_valid     (head_valid_next[lane]),
                .protocol_error (protocol_error[lane])
            );
        end
    endgenerate

    // 2. 根据非空状态选择一路；帧尾按出入队后的状态直接交接授权。
    frame_arbiter #(
        .PORTS (PORTS)
    ) scheduler (
        .clk            (clk),
        .rst            (rst),
        .mode_rr        (mode_rr),
        .available      (head_valid),
        .available_next (head_valid_next),
        .frame_done     (frame_done),
        .active         (grant_active),
        .source         (m_source)
    );

    // 3. 输出被授权 FIFO 的队首，只向该路返回 ready。
    stream_mux #(
        .PORTS      (PORTS),
        .DATA_WIDTH (DATA_WIDTH)
    ) output_mux (
        .rst        (rst),
        .active     (grant_active),
        .source     (m_source),
        .s_data     (head_data),
        .s_last     (head_last),
        .s_valid    (head_valid),
        .s_ready    (head_ready),
        .m_data     (m_data),
        .m_last     (m_last),
        .m_valid    (m_valid),
        .m_ready    (m_ready),
        .frame_done (frame_done)
    );
endmodule
