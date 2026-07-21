`timescale 1ns/1ps
// 帧级调度：先寄存授权，再允许输出；帧中断供时仍保留授权。
module frame_arbiter (
    input  wire       clk,
    input  wire       rst,
    input  wire       mode_rr,
    input  wire [3:0] available,
    input  wire       frame_done,
    output reg        active,
    output reg  [1:0] source
);
    reg rr;
    reg [1:0] cursor;
    reg found;
    reg [1:0] candidate;
    reg [1:0] index;
    integer offset;

    // 固定模式从 0 开始找；轮询从 cursor 开始，跳过空源。
    // index 为 2 位，赋值时自然对 4 取模。
    always @* begin
        found = 0;
        candidate = 0;
        index = 0;
        for (offset = 0; offset < 4; offset = offset + 1) begin
            index = rr ? (cursor + offset) : offset;
            if (!found && available[index]) begin
                found = 1;
                candidate = index;
            end
        end
    end

    // 只有空闲时接受候选；帧尾传输后释放，保留一拍仲裁空隙。
    always @(posedge clk) begin
        if (rst) begin
            rr <= mode_rr;
            cursor <= 0;
            active <= 0;
            source <= 0;
        end else if (!active) begin
            if (found) begin
                source <= candidate;
                active <= 1;
            end
        end else if (frame_done) begin
            active <= 0;
            cursor <= source + 2'd1;
        end
    end
endmodule
