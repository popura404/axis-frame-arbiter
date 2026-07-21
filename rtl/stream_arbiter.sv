`timescale 1ns/1ps
// 功能顶层：四路输入缓存 -> 帧级授权 -> 一路输出。
// 第 i 路数据位于 s_data[i*32 +: 32]，每帧固定 16 拍。
module stream_arbiter (
    input  wire         clk,
    input  wire         rst,
    input  wire         mode_rr,

    input  wire [127:0] s_data,
    input  wire [3:0]   s_last,
    input  wire [3:0]   s_valid,
    output wire [3:0]   s_ready,

    output wire [31:0]  m_data,
    output wire        m_last,
    output wire        m_valid,
    input  wire        m_ready,
    output wire [1:0]  m_source,

    output wire [3:0]   protocol_error,
    output wire [27:0]  fifo_level
);
    wire [127:0] head_data;
    wire [3:0] head_last;
    wire [3:0] head_valid;
    wire [3:0] head_ready;
    wire grant_active;
    wire frame_done;

    // 1. 每路独立缓存，同时监测输入帧格式与握手协议。
    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : inputs
            stream_fifo fifo (
                .clk            (clk),
                .rst            (rst),
                .s_data         (s_data[lane*32 +: 32]),
                .s_last         (s_last[lane]),
                .s_valid        (s_valid[lane]),
                .s_ready        (s_ready[lane]),
                .m_data         (head_data[lane*32 +: 32]),
                .m_last         (head_last[lane]),
                .m_valid        (head_valid[lane]),
                .m_ready        (head_ready[lane]),
                .level          (fifo_level[lane*7 +: 7]),
                .protocol_error (protocol_error[lane])
            );
        end
    endgenerate

    // 2. 根据非空状态选择一路，授权保持到该帧末拍成功传输。
    frame_arbiter scheduler (
        .clk        (clk),
        .rst        (rst),
        .mode_rr    (mode_rr),
        .available  (head_valid),
        .frame_done (frame_done),
        .active     (grant_active),
        .source     (m_source)
    );

    // 3. 输出被授权 FIFO 的队首，只向该路返回 ready。
    stream_mux output_mux (
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
