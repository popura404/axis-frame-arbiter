`timescale 1ns/1ps
// 只观察握手与 FIFO 水位，不参与流量控制。计数器按 32 位自然回绕。
// 每路计数放在 [lane*32 +: 32]，水位放在 [lane*7 +: 7]。
module perf_counters (
    input  wire         clk,
    input  wire         rst,
    input  wire         done,
    input  wire [3:0]   s_valid,
    input  wire [3:0]   s_ready,
    input  wire         m_valid,
    input  wire         m_ready,
    input  wire [27:0]  fifo_level,
    output reg  [127:0] input_words,
    output reg  [31:0]  elapsed_cycles,
    output reg  [31:0]  backpressure_cycles,
    output reg  [127:0] source_stall_cycles,
    output reg  [27:0]  fifo_peak
);
    integer lane;

    always @(posedge clk) begin
        if (rst) begin
            input_words         <= 0;
            elapsed_cycles      <= 0;
            backpressure_cycles <= 0;
            source_stall_cycles <= 0;
            fifo_peak           <= 0;
        end else begin
            if (!done) begin
                elapsed_cycles <= elapsed_cycles + 1'b1;
            end
            if (m_valid && !m_ready) begin
                backpressure_cycles <= backpressure_cycles + 1'b1;
            end

            for (lane = 0; lane < 4; lane = lane + 1) begin
                if (s_valid[lane] && s_ready[lane]) begin
                    input_words[lane*32 +: 32] <= input_words[lane*32 +: 32] + 1'b1;
                end
                if (s_valid[lane] && !s_ready[lane]) begin
                    source_stall_cycles[lane*32 +: 32] <= source_stall_cycles[lane*32 +: 32] + 1'b1;
                end
                if (fifo_level[lane*7 +: 7] > fifo_peak[lane*7 +: 7]) begin
                    fifo_peak[lane*7 +: 7] <= fifo_level[lane*7 +: 7];
                end
            end
        end
    end
endmodule
