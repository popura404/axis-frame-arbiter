`timescale 1ns/1ps
// 帧级调度：先寄存授权，再允许输出；帧中断供时仍保留授权。
module frame_arbiter (
    input  wire       clk,
    input  wire       rst,
    input  wire       mode_rr,
    input  wire [3:0] available,
    input  wire [3:0] available_next,
    input  wire       frame_done,
    output reg        active,
    output reg  [1:0] source
);
    reg rr;
    reg [1:0] cursor;
    reg found;
    reg [1:0] candidate;
    reg [1:0] index;
    reg [1:0] start;
    integer offset;

    // 固定模式从 0 开始找；轮询在帧尾从当前源的下一路开始。
    // 帧尾使用本沿出入队后的可用性，空闲时仍使用当前非空状态。
    // index 为 2 位，赋值时自然对 4 取模。
    always @* begin
        found = 0;
        candidate = 0;
        index = 0;
        start = frame_done ? (source + 2'd1) : cursor;
        for (offset = 0; offset < 4; offset = offset + 1) begin
            index = rr ? (start + offset) : offset;
            if (!found && (frame_done ? available_next[index] : available[index])) begin
                found = 1;
                candidate = index;
            end
        end
    end

    // 帧尾成功传输的同一边沿直接锁定下一授权，连续积压时无帧间空隙。
    // 帧尾阻塞或帧中断供时不重选，保持源号及有效输出稳定。
    always @(posedge clk) begin
        if (rst) begin
            rr <= mode_rr;
            cursor <= 0;
            active <= 0;
            source <= 0;
        end else begin
            if (!active || frame_done) begin
                active <= found;
                if (found)
                    source <= candidate;
            end
            if (frame_done)
                cursor <= source + 2'd1;
        end
    end
endmodule
