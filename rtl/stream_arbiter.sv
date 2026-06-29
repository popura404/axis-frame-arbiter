`timescale 1ns/1ps
// Four 32-bit, 16-beat framed streams. Lane i occupies [i*32 +: 32].
module stream_arbiter (
    input wire clk, input wire rst, input wire mode_rr,
    input wire [127:0] s_data, input wire [3:0] s_last,
    input wire [3:0] s_valid, output wire [3:0] s_ready,
    output wire [31:0] m_data, output wire m_last, output wire m_valid,
    input wire m_ready, output wire [1:0] m_source,
    output wire [3:0] protocol_error, output wire [27:0] fifo_level
);
    wire [127:0] head_data;
    wire [3:0] head_last, head_valid, head_ready;
    wire active;
    wire frame_done = m_valid && m_ready && m_last;
    genvar lane;
    generate for (lane = 0; lane < 4; lane = lane + 1) begin : inputs
        stream_fifo fifo (
            .clk(clk), .rst(rst), .s_data(s_data[lane*32 +: 32]),
            .s_last(s_last[lane]), .s_valid(s_valid[lane]), .s_ready(s_ready[lane]),
            .m_data(head_data[lane*32 +: 32]), .m_last(head_last[lane]),
            .m_valid(head_valid[lane]), .m_ready(head_ready[lane]),
            .level(fifo_level[lane*7 +: 7]), .protocol_error(protocol_error[lane])
        );
        assign head_ready[lane] = !rst && active && (m_source == lane) && m_ready;
    end endgenerate
    frame_arbiter scheduler (
        .clk(clk), .rst(rst), .mode_rr(mode_rr), .available(head_valid),
        .frame_done(frame_done), .active(active), .source(m_source)
    );
    // A separate mux wrapper would add no state or interface behavior.
    assign m_data = head_data[m_source*32 +: 32];
    assign m_last = head_last[m_source];
    assign m_valid = !rst && active && head_valid[m_source];
endmodule
