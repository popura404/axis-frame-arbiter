`timescale 1ns/1ps
// 按每路帧号和当前拍号推导期望载荷，独立检查数据、LAST 和帧内源号。
// 统计计数器按 32 位回绕，帧号按 24 位回绕；复位开始新一轮统计。
module sink_checker (
    input  wire         clk,
    input  wire         rst,
    input  wire [31:0]  data,
    input  wire         last,
    input  wire [1:0]   source,
    input  wire         valid,
    input  wire         ready,
    output reg  [31:0]  words,
    output reg  [127:0] frames,
    output reg  [31:0]  errors
);
    reg [23:0] next_frame [0:3];
    reg [3:0] next_beat;
    reg [1:0] frame_source;
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            words <= 0;
            frames <= 0;
            errors <= 0;
            next_beat <= 0;
            frame_source <= 0;
            for (i = 0; i < 4; i = i + 1) begin
                next_frame[i] <= 0;
            end
        end else if (valid && ready) begin
            words <= words + 1'b1;
            if (data != {source, 2'b00, next_frame[source], next_beat} ||
                last != (next_beat == 4'd15) ||
                (next_beat != 0 && source != frame_source)) begin
                errors <= errors + 1'b1;
            end
            if (next_beat == 0) begin
                frame_source <= source;
            end
            next_beat <= next_beat + 1'b1;
            if (next_beat == 4'd15) begin
                next_frame[source] <= next_frame[source] + 1'b1;
            end
            if (last) begin
                frames[source*32 +: 32] <= frames[source*32 +: 32] + 1'b1;
            end
        end
    end
endmodule
