`timescale 1ns/1ps
// 自测控制：选择负载、产生周期背压、排空判定和单次载荷注错。
// load_mode 在复位时采样：0=单源，1=四源满载，2=四源加周期背压。
module selftest_control (
    input  wire        clk,
    input  wire        rst,
    input  wire [1:0]  load_mode,
    input  wire        run,
    input  wire        inject_error,
    input  wire [3:0]  s_valid,
    input  wire [27:0] fifo_level,
    input  wire [31:0] m_data,
    input  wire        m_valid,
    output wire [3:0]  source_run,
    output wire        m_ready,
    output wire [31:0] checked_data,
    output wire        done
);
    reg [1:0] load_q;
    reg [4:0] phase;
    reg       inject_q;
    reg       inject_pending;

    wire transfer = m_valid && m_ready;

    assign source_run[0]   = run;
    assign source_run[3:1] = {3{run && (load_q != 2'd0)}};
    // 周期背压模式每 32 拍暂停接收前 8 拍。
    assign m_ready = (load_q != 2'd2) || (phase >= 5'd8);
    assign done = !run && (s_valid == 0) && (fifo_level == 0) && !m_valid;
    assign checked_data = m_data ^ {31'd0, inject_pending};

    always @(posedge clk) begin
        if (rst) begin
            load_q         <= load_mode;
            phase          <= 0;
            inject_q       <= 0;
            inject_pending <= 0;
        end else begin
            phase    <= phase + 1'b1;
            inject_q <= inject_error;

            // 上升沿登记注错，在下一次输出握手消费；挂起期间请求合并。
            // 保留消费优先级：消费与新请求同拍时不再登记第二次注错。
            if (inject_pending && transfer) begin
                inject_pending <= 0;
            end else if (inject_error && !inject_q) begin
                inject_pending <= 1;
            end
        end
    end
endmodule
