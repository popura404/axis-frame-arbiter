`timescale 1ns/1ps
// 功能顶层：多路输入缓存 -> 帧级授权 -> 一路输出。
// Fixed-16 watermark admission by default; optional bounded complete-frame mode.
module stream_arbiter #(
    parameter integer PORTS = 4,
    parameter integer DATA_WIDTH = 32,
    parameter integer FIFO_DEPTH = 64,
    // Each lane has a static 1..16 beat admission threshold; lane 0 is bits 4:0.
    parameter [PORTS*5-1:0] ADMISSION_LEVELS = {PORTS{5'd1}},
    parameter integer PACKET_MODE = 0,
    parameter integer MAX_FRAME_BEATS = FIFO_DEPTH,
    parameter integer KEEP_ENABLE = 0
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         mode_rr,

    input  wire [PORTS*DATA_WIDTH-1:0] s_data,
    input  wire [PORTS*(DATA_WIDTH/8)-1:0] s_keep,
    input  wire [PORTS-1:0] s_last,
    input  wire [PORTS-1:0] s_valid,
    output wire [PORTS-1:0] s_ready,

    output wire [DATA_WIDTH-1:0] m_data,
    output wire [DATA_WIDTH/8-1:0] m_keep,
    output wire        m_last,
    output wire        m_valid,
    input  wire        m_ready,
    output wire [$clog2(PORTS)-1:0] m_source,

    output wire [PORTS-1:0] protocol_error,
    output wire [PORTS*($clog2(FIFO_DEPTH)+1)-1:0] fifo_level
);
    localparam integer LEVEL_WIDTH = $clog2(FIFO_DEPTH) + 1;
    localparam integer KEEP_WIDTH = DATA_WIDTH / 8;
    localparam integer PAYLOAD_WIDTH = DATA_WIDTH + KEEP_WIDTH;
    wire [PORTS*DATA_WIDTH-1:0] head_data;
    wire [PORTS*KEEP_WIDTH-1:0] head_keep;
    wire [PORTS*PAYLOAD_WIDTH-1:0] head_payload;
    wire [PORTS-1:0] head_last;
    wire [PORTS-1:0] head_valid;
    wire [PORTS-1:0] eligible, eligible_next;
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
        if ((PACKET_MODE != 0 && PACKET_MODE != 1) ||
            MAX_FRAME_BEATS < 1 || MAX_FRAME_BEATS > FIFO_DEPTH ||
            (PACKET_MODE && ADMISSION_LEVELS != {PORTS{5'd1}})) begin : unsupported_packet
            STREAM_ARBITER_UNSUPPORTED_PACKET_PARAMETERS invalid_packet ();
        end
        if ((KEEP_ENABLE != 0 && KEEP_ENABLE != 1) ||
            (KEEP_ENABLE && !PACKET_MODE)) begin : unsupported_keep
            STREAM_ARBITER_UNSUPPORTED_KEEP_PARAMETERS invalid_keep ();
        end
        for (lane = 0; lane < PORTS; lane = lane + 1) begin : inputs
            localparam [4:0] ADMISSION = ADMISSION_LEVELS[lane*5 +: 5];
            wire [LEVEL_WIDTH-1:0] level = fifo_level[lane*LEVEL_WIDTH +: LEVEL_WIDTH];
            wire push = s_valid[lane] && s_ready[lane];
            wire pop = head_valid[lane] && head_ready[lane];
            wire frame_available, frame_available_next;
            wire [LEVEL_WIDTH-1:0] level_next = level +
                {{(LEVEL_WIDTH-1){1'b0}}, push} - {{(LEVEL_WIDTH-1){1'b0}}, pop};
            if (ADMISSION < 1 || ADMISSION > 16) begin : unsupported_admission
                STREAM_ARBITER_UNSUPPORTED_ADMISSION invalid_admission ();
            end
            // Admission is checked only when selecting a new frame. The mux
            // continues to use nonempty, independently of the threshold.
            assign eligible[lane] = PACKET_MODE ? frame_available : (!rst && (level >= ADMISSION));
            assign eligible_next[lane] = PACKET_MODE ? frame_available_next : (!rst && (level_next >= ADMISSION));
            assign head_payload[lane*PAYLOAD_WIDTH +: PAYLOAD_WIDTH] =
                {head_keep[lane*KEEP_WIDTH +: KEEP_WIDTH], head_data[lane*DATA_WIDTH +: DATA_WIDTH]};
            stream_fifo #(
                .DATA_WIDTH (DATA_WIDTH),
                .FIFO_DEPTH (FIFO_DEPTH),
                .PACKET_MODE (PACKET_MODE),
                .MAX_FRAME_BEATS (MAX_FRAME_BEATS),
                .KEEP_ENABLE (KEEP_ENABLE)
            ) fifo (
                .clk            (clk),
                .rst            (rst),
                .s_data         (s_data[lane*DATA_WIDTH +: DATA_WIDTH]),
                .s_keep         (s_keep[lane*KEEP_WIDTH +: KEEP_WIDTH]),
                .s_last         (s_last[lane]),
                .s_valid        (s_valid[lane]),
                .s_ready        (s_ready[lane]),
                .m_data         (head_data[lane*DATA_WIDTH +: DATA_WIDTH]),
                .m_keep         (head_keep[lane*KEEP_WIDTH +: KEEP_WIDTH]),
                .m_last         (head_last[lane]),
                .m_valid        (head_valid[lane]),
                .m_ready        (head_ready[lane]),
                .level          (fifo_level[lane*LEVEL_WIDTH +: LEVEL_WIDTH]),
                .next_valid     (),
                .protocol_error (protocol_error[lane]),
                .frame_available (frame_available),
                .frame_available_next (frame_available_next)
            );
        end
    endgenerate

    // 2. 根据准入水位选择一路；帧尾按出入队后的状态直接交接授权。
    frame_arbiter #(
        .PORTS (PORTS)
    ) scheduler (
        .clk            (clk),
        .rst            (rst),
        .mode_rr        (mode_rr),
        .available      (eligible),
        .available_next (eligible_next),
        .frame_done     (frame_done),
        .active         (grant_active),
        .source         (m_source)
    );

    // 3. 输出被授权 FIFO 的队首，只向该路返回 ready。
    stream_mux #(
        .PORTS      (PORTS),
        .DATA_WIDTH (PAYLOAD_WIDTH)
    ) output_mux (
        .rst        (rst),
        .active     (grant_active),
        .source     (m_source),
        .s_data     (head_payload),
        .s_last     (head_last),
        .s_valid    (head_valid),
        .s_ready    (head_ready),
        .m_data     ({m_keep, m_data}),
        .m_last     (m_last),
        .m_valid    (m_valid),
        .m_ready    (m_ready),
        .frame_done (frame_done)
    );
endmodule
