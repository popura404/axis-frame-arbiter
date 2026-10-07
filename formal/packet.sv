`timescale 1ns/1ps
// Bounded real-RTL scenario, checked only through interface handshakes.
// Source 0: legal 2-beat frame, then either 3 non-LAST beats or a bad KEEP tail.
// Source 1: legal 3-beat frame offered after source 0's fault.
// Length case: READY=0 for the five-beat preload, then arbitrary.
// KEEP case: READY=1 through cycle 4; the old tail leaves on the bad KEEP input
// edge. Thereafter READY is arbitrary. Only the initial reset is modeled.
// Payloads and frame boundaries are a pre-registered sequence, not a copy of
// the DUT's complete-frame counter. This is not an arbitrary-traffic proof.
module formal_packet #(parameter integer KEEP_FAULT = 0)(input wire clk);
    localparam integer FAULT_AFTER = KEEP_FAULT ? 3 : 5;
    reg rst = 1;
    always @(posedge clk) rst <= 0;
    reg [5:0] elapsed;
    (* anyseq *) reg m_ready;
    wire [1:0] s_valid, s_last, s_ready, protocol_error;
    wire [63:0] s_data;
    wire [7:0] s_keep;
    wire [3:0] m_keep;
    wire [31:0] m_data;
    wire m_last, m_valid, m_source;
    wire [9:0] fifo_level;
    reg [2:0] accepted0;
    reg [1:0] accepted1, emitted0, emitted1;
    reg output_stalled, frame_open, frame_source;
    reg [37:0] output_held;
    reg saw_stalled_tail, saw_bad_tail_overlap;

    assign s_valid[0] = !rst && (!KEEP_FAULT || accepted0 < 2 || elapsed >= 4);
    assign s_valid[1] = !rst && elapsed >= 5 && accepted1 < 3;
    assign s_data[31:0] = 32'h12340000 | {29'd0, accepted0};
    assign s_data[63:32] = 32'h56780000 | {30'd0, accepted1};
    assign s_last[0] = accepted0 == 1 || (KEEP_FAULT ? accepted0 >= 2 : accepted0 == 5);
    assign s_last[1] = accepted1 == 2;
    assign s_keep[3:0] = accepted0 == 1 ? 4'b0011 :
                            (KEEP_FAULT && accepted0 == 2) ? 4'b0101 :
                            s_last[0] ? 4'b0001 : 4'b1111;
    assign s_keep[7:4] = s_last[1] ? 4'b0111 : 4'b1111;

    function automatic [31:0] byte_mask(input [3:0] keep);
        byte_mask = {{8{keep[3]}}, {8{keep[2]}}, {8{keep[1]}}, {8{keep[0]}}};
    endfunction

    stream_arbiter #(
        .PORTS(2), .DATA_WIDTH(32), .FIFO_DEPTH(16),
        .PACKET_MODE(1), .MAX_FRAME_BEATS(3), .KEEP_ENABLE(1)
    ) dut (
        .clk(clk), .rst(rst), .mode_rr(1'b1),
        .s_data(s_data), .s_last(s_last), .s_keep(s_keep), .s_valid(s_valid), .s_ready(s_ready),
        .m_data(m_data), .m_last(m_last), .m_keep(m_keep), .m_valid(m_valid), .m_ready(m_ready),
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
            saw_bad_tail_overlap <= 0;
        end else begin
            if (elapsed != 63) elapsed <= elapsed + 1'b1;
            if (KEEP_FAULT) begin
                if (elapsed <= 4) assume(m_ready);
            end else if (elapsed < 5) assume(!m_ready);
            if (s_valid[0] && s_ready[0]) accepted0 <= accepted0 + 1'b1;
            if (s_valid[1] && s_ready[1]) accepted1 <= accepted1 + 1'b1;

            // Fault location is fixed by the pre-registered source sequence.
            // The pending legal LAST stays valid and stable after quarantine.
            assert(accepted0 <= FAULT_AFTER);
            if (accepted0 == FAULT_AFTER) begin
                assert(protocol_error[0]);
                assert(!s_ready[0]);
            end else assert(!protocol_error[0]);
            assert(!protocol_error[1]);
            assert(fifo_level[4:0] == accepted0 - emitted0);
            assert(fifo_level[9:5] == accepted1 - emitted1);

            if (output_stalled) begin
                assert(m_valid);
                assert({m_source, m_last, m_keep, m_data} == output_held);
            end
            output_stalled <= m_valid && !m_ready;
            output_held <= {m_source, m_last, m_keep, m_data};
            if (frame_open) begin
                assert(m_valid);
                assert(m_source == frame_source);
            end

            if (m_valid) begin
                if (!m_source) begin
                    // Only the two pre-registered good beats may be exposed.
                    assert(accepted0 >= 2 && emitted0 < 2);
                    assert(m_keep == (emitted0 == 1 ? 4'b0011 : 4'b1111));
                    assert((m_data & byte_mask(m_keep)) ==
                           ((32'h12340000 | {30'd0, emitted0}) & byte_mask(m_keep)));
                    assert(m_last == (emitted0 == 1));
                end else begin
                    assert(accepted1 == 3 && emitted1 < 3);
                    assert(m_keep == (emitted1 == 2 ? 4'b0111 : 4'b1111));
                    assert((m_data & byte_mask(m_keep)) ==
                           ((32'h56780000 | {30'd0, emitted1}) & byte_mask(m_keep)));
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
            if (KEEP_FAULT && accepted0 == 2 && s_valid[0] && s_ready[0] &&
                m_valid && m_ready && !m_source && m_last) saw_bad_tail_overlap <= 1;
            cover(protocol_error[0] && !s_ready[0] && emitted0 == 2 && emitted1 == 3 &&
                  (!KEEP_FAULT || saw_bad_tail_overlap));
            cover(protocol_error[0] && saw_stalled_tail && emitted0 == 2 && emitted1 == 3 &&
                  (!KEEP_FAULT || saw_bad_tail_overlap));
        end
    end
endmodule
