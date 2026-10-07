`timescale 1ns/1ps
// Real RTL, interface-only assumptions/checks. No DUT hierarchy references.
// Data are per-source sequence tags: this proves tagged flow/control properties,
// not arbitrary 32-bit payload equivalence. See scripts/formal.py result scope.
module formal_admission #(
    parameter integer G = 2,
    parameter integer H = 9,
    parameter integer CHECK_DATA = 0,
    parameter integer SCENARIO = 1,
    parameter integer CONTINUOUS_READY = 1
) (input wire clk);
    localparam integer PORTS = 2;
    reg rst = 1;
    reg [6:0] elapsed;
    always @(posedge clk) rst <= 0;

    (* anyseq *) reg [1:0] s_valid;
    (* anyseq *) reg m_ready;
    wire [1:0] s_ready, s_last, protocol_error;
    wire [63:0] s_data;
    wire [31:0] m_data;
    wire m_valid, m_last, m_source;
    wire [9:0] fifo_level;
    reg [7:0] input_sequence [0:1];
    reg [7:0] output_sequence [0:1];
    reg [3:0] missed [0:1];
    reg [1:0] held_valid;
    reg output_stalled;
    reg [1:0] output_held;
    reg [31:0] data_held;
    reg frame_open;
    reg frame_source;
    reg [3:0] frame_beat;
    reg [1:0] completed;
    reg saw_tail_handoff;
    reg prior_tail;
    integer lane;

    genvar p;
    generate for (p=0; p<2; p=p+1) begin : source
        assign s_data[p*32 +: 32] = CHECK_DATA ? {16'd0, 8'(p), input_sequence[p]} : 32'd0;
        assign s_last[p] = input_sequence[p][3:0] == 15;
    end endgenerate

    stream_arbiter #(
        .PORTS(2), .DATA_WIDTH(32), .FIFO_DEPTH(16),
        .ADMISSION_LEVELS({5'(H), 5'(H)}), .KEEP_ENABLE(0)
    ) dut (
        .clk(clk), .rst(rst), .mode_rr(1'b1),
        .s_data(s_data), .s_last(s_last), .s_keep(8'hff), .s_valid(s_valid), .s_ready(s_ready),
        .m_data(m_data), .m_last(m_last), .m_keep(), .m_valid(m_valid), .m_ready(m_ready),
        .m_source(m_source), .protocol_error(protocol_error), .fifo_level(fifo_level)
    );

    always @(posedge clk) begin
        if (rst) begin
            elapsed <= 0;
            held_valid <= 0;
            output_stalled <= 0;
            output_held <= 0;
            data_held <= 0;
            frame_open <= 0;
            frame_source <= 0;
            frame_beat <= 0;
            completed <= 0;
            saw_tail_handoff <= 0;
            prior_tail <= 0;
            for (lane=0; lane<2; lane=lane+1) begin
                input_sequence[lane] <= 0;
                output_sequence[lane] <= 0;
                missed[lane] <= 0;
            end
        end else begin
            if (CONTINUOUS_READY) assume(m_ready);
            if (elapsed != 127) elapsed <= elapsed + 1'b1;
            // Focused real-RTL witness: source 0 supplies one complete frame.
            // Its registered idle grant makes its tail transfer at H+16.
            // Source 1 supplies its Hth prefix beat on that exact edge. After
            // this fixed setup, source supply and downstream READY are free
            // except for the same contract and valid-hold assumptions below.
            if (SCENARIO) begin
                assume(s_valid[0] == (elapsed < 16));
                if (elapsed <= H+16) begin
                    assume(m_ready);
                    assume(s_valid[1] == (elapsed >= 17));
                end else if (input_sequence[1] == 16)
                    assume(!s_valid[1]);
            end
            for (lane=0; lane<2; lane=lane+1) begin
                // Payload/tag and LAST change only after acceptance. VALID must
                // also remain asserted while the previously offered beat stalls.
                if (held_valid[lane]) assume(s_valid[lane]);
                held_valid[lane] <= s_valid[lane] && !s_ready[lane];
                // No deadline before the first beat or between frames.
                // Only READY opportunities count; READY=0 freezes the budget.
                if (input_sequence[lane][3:0] != 0 && s_ready[lane])
                    assume(s_valid[lane] || missed[lane] < G-1);
                if (s_valid[lane] && s_ready[lane]) begin
                    input_sequence[lane] <= input_sequence[lane] + 1'b1;
                    missed[lane] <= 0;
                end else if (input_sequence[lane][3:0] != 0 && s_ready[lane])
                    missed[lane] <= missed[lane] + 1'b1;
            end

            assert(protocol_error == 0);
            if (frame_open) begin
                assert(m_valid); // conditional no-underflow property
                if (m_valid) assert(m_source == frame_source);
            end
            if (output_stalled) begin
                assert(m_valid);
                assert({m_source, m_last} == output_held);
                if (CHECK_DATA) assert(m_data == data_held);
            end
            output_stalled <= m_valid && !m_ready;
            output_held <= {m_source, m_last};
            data_held <= m_data;
            if (m_valid) begin
                if (CHECK_DATA)
                    assert(m_data == {16'd0, 7'd0, m_source, output_sequence[m_source]});
                assert(m_last == (frame_beat == 15));
            end
            if (m_valid && m_ready) begin
                output_sequence[m_source] <= output_sequence[m_source] + 1'b1;
                if (m_last) begin
                    frame_open <= 0;
                    frame_beat <= 0;
                    completed[m_source] <= 1;
                end else begin
                    frame_open <= 1;
                    frame_source <= m_source;
                    frame_beat <= frame_beat + 1'b1;
                end
            end
            if (prior_tail && m_valid) saw_tail_handoff <= 1;
            prior_tail <= m_valid && m_ready && m_last;
            cover(&completed && saw_tail_handoff);
            if (!CONTINUOUS_READY) cover(output_stalled && frame_open);
        end
    end
endmodule
