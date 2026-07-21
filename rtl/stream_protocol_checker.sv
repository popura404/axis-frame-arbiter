`timescale 1ns/1ps
// 检查每 16 拍的 LAST，以及背压期间 VALID/DATA/LAST 是否保持。
// 错误保持到复位，只报告，不丢弃或修复输入数据。
module stream_protocol_checker (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] data,
    input  wire        last,
    input  wire        valid,
    input  wire        ready,
    output reg         protocol_error
);
    reg [3:0] beat;
    reg stalled;
    reg [32:0] held;

    always @(posedge clk) begin
        if (rst) begin
            beat <= 0;
            stalled <= 0;
            held <= 0;
            protocol_error <= 0;
        end else begin
            // 上拍未被接受的数据，本拍仍必须有效且内容不变。
            if (stalled && (!valid || {last, data} != held))
                protocol_error <= 1;
            stalled <= valid && !ready;
            held <= {last, data};

            if (valid && ready) begin
                if (last != (beat == 4'd15))
                    protocol_error <= 1;

                // 饱和在第 16 拍，避免超长帧计数回绕后被误判为合法。
                if (last)
                    beat <= 0;
                else if (beat != 4'd15)
                    beat <= beat + 1'b1;
            end
        end
    end
endmodule
