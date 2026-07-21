`timescale 1ns/1ps
// 四选一数据通路：根据已锁定的授权转发数据和反压，不保存状态。
module stream_mux (
    input  wire         rst,
    input  wire         active,
    input  wire [1:0]   source,

    input  wire [127:0] s_data,
    input  wire [3:0]   s_last,
    input  wire [3:0]   s_valid,
    output wire [3:0]   s_ready,

    output wire [31:0]  m_data,
    output wire        m_last,
    output wire        m_valid,
    input  wire        m_ready,
    output wire        frame_done
);
    assign m_data = s_data[source*32 +: 32];
    assign m_last = s_last[source];
    assign m_valid = !rst && active && s_valid[source];
    assign frame_done = m_valid && m_ready && m_last;

    // 未获授权的 FIFO 不弹出；获授权但为空时，FIFO 自身也不会弹出。
    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : ready_routes
            assign s_ready[lane] = !rst && active && (source == lane) && m_ready;
        end
    endgenerate
endmodule
