`timescale 1ns/1ps
// Pack LAST with DATA and monitor each input's 16-beat frame protocol.
// Sticky errors diagnose malformed frames / unstable stalled inputs. No repair.
module stream_fifo (
    input wire clk, input wire rst,
    input wire [31:0] s_data, input wire s_last, input wire s_valid,
    output wire s_ready,
    output wire [31:0] m_data, output wire m_last, output wire m_valid,
    input wire m_ready, output wire [6:0] level,
    output reg protocol_error
);
    reg [3:0] beat;
    reg stalled;
    reg [32:0] held;
    sync_fifo fifo (
        .clk(clk), .rst(rst), .s_data({s_last,s_data}),
        .s_valid(s_valid), .s_ready(s_ready), .m_data({m_last,m_data}),
        .m_valid(m_valid), .m_ready(m_ready), .level(level)
    );
    always @(posedge clk) begin
        if (rst) begin
            beat <= 0;
            stalled <= 0;
            held <= 0;
            protocol_error <= 0;
        end else begin
            if (stalled && (!s_valid || {s_last,s_data} != held))
                protocol_error <= 1;
            stalled <= s_valid && !s_ready;
            held <= {s_last,s_data};
            if (s_valid && s_ready) begin
                if (s_last != (beat == 15)) protocol_error <= 1;
                // Saturation prevents an overlong frame looking legal on wrap.
                if (s_last) beat <= 0;
                else if (beat != 15) beat <= beat + 1'b1;
            end
        end
    end
endmodule
