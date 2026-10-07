`timescale 1ns/1ps
// Per-lane storage of DATA/LAST and optional KEEP, with frame admission metadata.
module stream_fifo #(
    parameter integer DATA_WIDTH = 32,
    parameter integer FIFO_DEPTH = 64,
    parameter integer PACKET_MODE = 0,
    parameter integer MAX_FRAME_BEATS = FIFO_DEPTH,
    parameter integer KEEP_ENABLE = 0
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [DATA_WIDTH-1:0] s_data,
    input  wire [DATA_WIDTH/8-1:0] s_keep,
    input  wire        s_last,
    input  wire        s_valid,
    output wire        s_ready,

    output wire [DATA_WIDTH-1:0] m_data,
    output wire [DATA_WIDTH/8-1:0] m_keep,
    output wire        m_last,
    output wire        m_valid,
    input  wire        m_ready,

    output wire [$clog2(FIFO_DEPTH):0] level,
    output wire        next_valid,
    output wire        protocol_error,
    output wire        frame_available,
    output wire        frame_available_next
);
    wire fifo_ready, frame_bad, frame_fault;
    wire accepting = !PACKET_MODE || !frame_fault;
    assign s_ready = fifo_ready && accepting;
    localparam integer KEEP_WIDTH = DATA_WIDTH / 8;
    localparam integer STORAGE_WIDTH = DATA_WIDTH + 1 + (KEEP_ENABLE ? KEEP_WIDTH : 0);
    wire [STORAGE_WIDTH-1:0] storage_in, storage_out;
    generate
        if (KEEP_ENABLE) begin : byte_qualifiers
            assign storage_in = {s_keep, s_last, s_data};
            assign {m_keep, m_last, m_data} = storage_out;
        end else begin : full_words
            assign storage_in = {s_last, s_data};
            assign {m_last, m_data} = storage_out;
            assign m_keep = {KEEP_WIDTH{1'b1}};
        end
    endgenerate

    sync_fifo #(
        .WIDTH (STORAGE_WIDTH),
        .DEPTH (FIFO_DEPTH)
    ) fifo (
        .clk        (clk),
        .rst        (rst),
        .s_data     (storage_in),
        .s_valid    (s_valid && accepting),
        .s_ready    (fifo_ready),
        .m_data     (storage_out),
        .m_valid    (m_valid),
        .m_ready    (m_ready),
        .level      (level),
        .next_valid (next_valid)
    );

    stream_protocol_checker #(
        .DATA_WIDTH (DATA_WIDTH),
        .PACKET_MODE (PACKET_MODE),
        .MAX_FRAME_BEATS (MAX_FRAME_BEATS),
        .KEEP_ENABLE (KEEP_ENABLE)
    ) protocol_monitor (
        .clk            (clk),
        .rst            (rst),
        .data           (s_data),
        .keep           (s_keep),
        .last           (s_last),
        .valid          (s_valid),
        .ready          (s_ready),
        .protocol_error (protocol_error),
        .frame_bad      (frame_bad),
        .frame_fault    (frame_fault)
    );

    generate
        if (PACKET_MODE) begin : packets
            // A depth-D FIFO can contain D one-beat frames. Complete frames
            // always precede the unfinished tail; no rollback pointer is needed.
            localparam integer COUNT_WIDTH = $clog2(FIFO_DEPTH) + 1;
            reg [COUNT_WIDTH-1:0] complete_frames;
            wire commit_frame = s_valid && s_ready && s_last && !frame_bad;
            wire finish_frame = m_valid && m_ready && m_last;
            wire [COUNT_WIDTH-1:0] complete_next = complete_frames +
                {{(COUNT_WIDTH-1){1'b0}}, commit_frame} -
                {{(COUNT_WIDTH-1){1'b0}}, finish_frame};
            assign frame_available = !rst && (complete_frames != 0);
            assign frame_available_next = !rst && (complete_next != 0);
            always @(posedge clk) begin
                if (rst) complete_frames <= 0;
                else complete_frames <= complete_next;
            end
        end else begin : words
            assign frame_available = 1'b0;
            assign frame_available_next = 1'b0;
        end
    endgenerate
endmodule
