`timescale 1ns/1ps
// 单时钟 FIFO：分布式 RAM，队首组合可见。
// 复位只清指针和占用量；满时即使本拍读出，也在下一拍才恢复接收。
module sync_fifo #(
    parameter integer WIDTH = 33,
    parameter integer DEPTH = 64,
    parameter integer AW = $clog2(DEPTH)
) (
    input  wire             clk,
    input  wire             rst,
    input  wire [WIDTH-1:0] s_data,
    input  wire             s_valid,
    output wire             s_ready,
    output wire [WIDTH-1:0] m_data,
    output wire             m_valid,
    input  wire             m_ready,
    output reg  [AW:0]      level,
    output wire             next_valid
);
    (* ram_style = "distributed" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW-1:0] wr_ptr;
    reg [AW-1:0] rd_ptr;
    wire push = s_valid && s_ready;
    wire pop = m_valid && m_ready;

    assign s_ready = !rst && (level < DEPTH);
    assign m_valid = !rst && (level != 0);
    assign m_data = mem[rd_ptr];
    // 供帧尾重授权使用：包含本沿成功写入，排除弹出的唯一队头。
    // 不改变当前拍 m_valid 或满时反压规则。
    assign next_valid = !rst && ((level > 1) || ((level == 1) && !pop) || push);

    // 只有握手成功才移动指针，同时读写时占用量不变。
    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            level <= 0;
        end else begin
            if (push) begin
                mem[wr_ptr] <= s_data;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (pop)
                rd_ptr <= rd_ptr + 1'b1;
            case ({push, pop})
                2'b10: level <= level + 1'b1;
                2'b01: level <= level - 1'b1;
                default: ;
            endcase
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (DEPTH < 2 || (DEPTH & (DEPTH-1)) != 0)
            $fatal(1, "sync_fifo DEPTH must be a power of two >= 2");
    end
`endif
endmodule
