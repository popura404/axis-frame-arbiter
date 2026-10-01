`timescale 1ns/1ps
// Bounded real-RTL scenario, checked only through interface handshakes.
// Source 0: legal 2-beat frame, then 3 non-LAST beats and a blocked pending tail.
// Source 1: legal 3-beat frame offered after source 0's fault.
// READY=0 for the five-beat preload, then arbitrary. Initial reset only.
// Payloads and frame boundaries are a pre-registered sequence, not a copy of
// the DUT's complete-frame counter. This is not an arbitrary-traffic proof.
module formal_packet(input wire clk);
    reg rst = 1;
    always @(posedge clk) rst <= 0;
    reg [5:0] elapsed;
    (* anyseq *) reg m_ready;
    wire [1:0] s_valid, s_last, s_ready, protocol_error;
    wire [63:0] s_data;
    wire [31:0] m_data;
    wire m_last, m_valid, m_source;
    wire [9:0] fifo_level;
    reg [2:0] accepted0;
    reg [1:0] accepted1, emitted0, emitted1;
    reg output_stalled, frame_open, frame_source;
    reg [33:0] output_held;
    reg saw_stalled_tail;

    assign s_valid[0] = !rst;
    assign s_valid[1] = !rst && elapsed >= 5 && accepted1 < 3;
    assign s_data[31:0] = 32'h12340000 | {29'd0, accepted0};
    assign s_data[63:32] = 32'h56780000 | {30'd0, accepted1};
    assign s_last[0] = accepted0 == 1 || accepted0 == 5;
    assign s_last[1] = accepted1 == 2;

    stream_arbiter #(
        .PORTS(2), .DATA_WIDTH(32), .FIFO_DEPTH(16),
        .PACKET_MODE(1), .MAX_FRAME_BEATS(3)
    ) dut (
        .clk(clk), .rst(rst), .mode_rr(1'b1),
        .s_data(s_data), .s_last(s_last), .s_valid(s_valid), .s_ready(s_ready),
        .m_data(m_data), .m_last(m_last), .m_valid(m_valid), .m_ready(m_ready),
        .m_source(m_source), .protocol_error(protocol_error), .fifo_level(fifo_level)
    );

    always @(posedge clk) begin
        if (rst) begin
            elapsed <= 0;
            accepted0 <= 0;
            accepted1 <= 0;
            emitted0 <= 0;
            emitted1 <= 0;
            output_stalled <= 0;
            output_held <= 0;
            frame_open <= 0;
            frame_source <= 0;
            saw_stalled_tail <= 0;
        end else begin
            if (elapsed != 63) elapsed <= elapsed + 1'b1;
            if (elapsed < 5) assume(!m_ready);
            if (s_valid[0] && s_ready[0]) accepted0 <= accepted0 + 1'b1;
            if (s_valid[1] && s_ready[1]) accepted1 <= accepted1 + 1'b1;

            // The fifth accepted source-0 beat is the unterminated frame's
            // third beat. The pending LAST remains valid and stable afterward.
            assert(accepted0 <= 5);
            if (accepted0 == 5) begin
                assert(protocol_error[0]);
                assert(!s_ready[0]);
            end else assert(!protocol_error[0]);
            assert(!protocol_error[1]);
            assert(fifo_level[4:0] == accepted0 - emitted0);
            assert(fifo_level[9:5] == accepted1 - emitted1);

            if (output_stalled) begin
                assert(m_valid);
                assert({m_source, m_last, m_data} == output_held);
            end
            output_stalled <= m_valid && !m_ready;
            output_held <= {m_source, m_last, m_data};
            if (frame_open) begin
                assert(m_valid);
                assert(m_source == frame_source);
            end

            if (m_valid) begin
                if (!m_source) begin
                    // Only the two pre-registered good beats may be exposed.
                    assert(accepted0 >= 2 && emitted0 < 2);
                    assert(m_data == (32'h12340000 | {30'd0, emitted0}));
                    assert(m_last == (emitted0 == 1));
                end else begin
                    assert(accepted1 == 3 && emitted1 < 3);
                    assert(m_data == (32'h56780000 | {30'd0, emitted1}));
                    assert(m_last == (emitted1 == 2));
                end
                if (!m_ready && m_last) saw_stalled_tail <= 1;
            end
            if (m_valid && m_ready) begin
                if (m_source) emitted1 <= emitted1 + 1'b1;
                else emitted0 <= emitted0 + 1'b1;
                frame_open <= !m_last;
                frame_source <= m_source;
            end
            cover(protocol_error[0] && !s_ready[0] && emitted0 == 2 && emitted1 == 3);
            cover(protocol_error[0] && saw_stalled_tail && emitted0 == 2 && emitted1 == 3);
        end
    end
endmodule
