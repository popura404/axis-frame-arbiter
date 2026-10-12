`timescale 1ns/1ps
// Shared synthesis boundary for the RFNoC record comparison. Source event
// storage, serialization and CDC remain common and are measured separately.
module rfnoc_arbiter #(
    parameter integer EXTERNAL = 0,
    parameter integer PORTS = 4,
    parameter integer DATA_WIDTH = 32,
    parameter integer FIFO_DEPTH = 16,
    parameter integer MAX_FRAME_BEATS = 6
) (
    input wire clk,
    input wire rst,
    input wire [PORTS*DATA_WIDTH-1:0] s_data,
    input wire [PORTS-1:0] s_last,
    input wire [PORTS-1:0] s_valid,
    output wire [PORTS-1:0] s_ready,
    output wire [DATA_WIDTH-1:0] m_data,
    output wire m_last,
    output wire m_valid,
    input wire m_ready,
    output wire [$clog2(PORTS)-1:0] m_source,
    output wire [PORTS-1:0] protocol_error
);
    generate
        if ((EXTERNAL != 0 && EXTERNAL != 1) ||
            MAX_FRAME_BEATS < 1 || MAX_FRAME_BEATS > FIFO_DEPTH) begin : unsupported_configuration
            RFNOC_ARBITER_UNSUPPORTED_PARAMETERS invalid_configuration ();
        end
        if (EXTERNAL) begin : external_candidate
            axis_external #(
                .PORTS(PORTS), .DATA_WIDTH(DATA_WIDTH), .FIFO_DEPTH(FIFO_DEPTH),
                .FRAME_FIFO(1), .FRAME_LIMIT(MAX_FRAME_BEATS)
            ) candidate (.*);
        end else begin : native_candidate
            stream_arbiter #(
                .PORTS(PORTS), .DATA_WIDTH(DATA_WIDTH), .FIFO_DEPTH(FIFO_DEPTH),
                .ADMISSION_LEVELS({PORTS{5'd1}}), .PACKET_MODE(1),
                .MAX_FRAME_BEATS(MAX_FRAME_BEATS), .KEEP_ENABLE(0)
            ) candidate (
                .clk(clk), .rst(rst), .mode_rr(1'b1),
                .s_data(s_data), .s_last(s_last), .s_valid(s_valid), .s_ready(s_ready),
                .s_keep({PORTS*(DATA_WIDTH/8){1'b1}}),
                .m_data(m_data), .m_last(m_last), .m_valid(m_valid), .m_ready(m_ready),
                .m_source(m_source), .m_keep(), .protocol_error(protocol_error), .fifo_level()
            );
        end
    endgenerate
endmodule
