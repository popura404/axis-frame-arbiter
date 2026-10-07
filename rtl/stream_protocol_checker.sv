`timescale 1ns/1ps
// Fixed mode checks 16 beats; packet mode bounds each frame by MAX_FRAME_BEATS.
// Length faults in packet mode quarantine further input until reset.
module stream_protocol_checker #(
    parameter integer DATA_WIDTH = 32,
    parameter integer PACKET_MODE = 0,
    parameter integer MAX_FRAME_BEATS = 64,
    parameter integer KEEP_ENABLE = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [DATA_WIDTH-1:0] data,
    input  wire [DATA_WIDTH/8-1:0] keep,
    input  wire        last,
    input  wire        valid,
    input  wire        ready,
    output reg         protocol_error,
    output wire        frame_bad,
    output reg         frame_fault
);
    localparam integer FRAME_LIMIT = PACKET_MODE ? MAX_FRAME_BEATS : 16;
    localparam integer BEAT_WIDTH = (FRAME_LIMIT > 1) ? $clog2(FRAME_LIMIT) : 1;
    localparam [BEAT_WIDTH-1:0] LAST_BEAT = FRAME_LIMIT - 1;
    reg [BEAT_WIDTH-1:0] beat;
    reg stalled;
    localparam integer KEEP_WIDTH = DATA_WIDTH / 8;
    wire [KEEP_WIDTH-1:0] effective_keep = KEEP_ENABLE ? keep : {KEEP_WIDTH{1'b1}};
    wire [KEEP_WIDTH-1:0] keep_plus_one = keep + 1'b1;
    wire keep_bad = KEEP_ENABLE && ((keep == 0) ||
        (!last && keep != {KEEP_WIDTH{1'b1}}) || (last && ((keep & keep_plus_one) != 0)));
    reg [DATA_WIDTH+KEEP_WIDTH:0] held;

    // Sample frame_bad only on an accepted beat. A bad tail must not commit.
    assign frame_bad = PACKET_MODE ? (((beat == LAST_BEAT) && !last) || keep_bad) :
                                    (last != (beat == LAST_BEAT));

    always @(posedge clk) begin
        if (rst) begin
            beat <= 0;
            stalled <= 0;
            held <= 0;
            protocol_error <= 0;
            frame_fault <= 0;
        end else begin
            // 上拍未被接受的数据，本拍仍必须有效且内容不变。
            if (stalled && (!valid || {effective_keep, last, data} != held))
                protocol_error <= 1;
            stalled <= valid && !ready;
            held <= {effective_keep, last, data};

            if (valid && ready) begin
                if (frame_bad)
                    protocol_error <= 1;
                if (PACKET_MODE && frame_bad)
                    frame_fault <= 1;

                // Saturate instead of wrapping on an unterminated frame.
                if (last)
                    beat <= 0;
                else if (beat != LAST_BEAT)
                    beat <= beat + 1'b1;
            end
        end
    end
endmodule
