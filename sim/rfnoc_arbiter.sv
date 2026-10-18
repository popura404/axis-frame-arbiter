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
        if ((EXTERNAL < 0 || EXTERNAL > 2) ||
            MAX_FRAME_BEATS < 1 || MAX_FRAME_BEATS > FIFO_DEPTH) begin : unsupported_configuration
            RFNOC_ARBITER_UNSUPPORTED_PARAMETERS invalid_configuration ();
        end
        if (EXTERNAL == 2) begin : rr_only_candidate
            localparam integer SOURCE_WIDTH = $clog2(PORTS);
            localparam integer KEEP_WIDTH = DATA_WIDTH / 8;
            wire [PORTS*SOURCE_WIDTH-1:0] source_id;
            wire [PORTS-1:0] input_ready;
            wire output_valid;
            // No second frame FIFO or length checker. The unchanged mux keeps
            // one input slot per lane and two shared output/skid slots.
            for (genvar lane = 0; lane < PORTS; lane = lane+1) begin : source_ids
                localparam [SOURCE_WIDTH-1:0] SOURCE_ID = lane;
                assign source_id[lane*SOURCE_WIDTH +: SOURCE_WIDTH] = SOURCE_ID;
            end
            assign s_ready = input_ready & {PORTS{!rst}};
            assign m_valid = output_valid && !rst;
            assign protocol_error = {PORTS{1'b0}};
            axis_arb_mux #(
                .S_COUNT(PORTS), .DATA_WIDTH(DATA_WIDTH),
                .KEEP_ENABLE(0), .KEEP_WIDTH(KEEP_WIDTH), .LAST_ENABLE(1),
                .ID_ENABLE(1), .S_ID_WIDTH(SOURCE_WIDTH), .M_ID_WIDTH(SOURCE_WIDTH),
                .UPDATE_TID(0), .DEST_ENABLE(0), .DEST_WIDTH(1),
                .USER_ENABLE(0), .USER_WIDTH(1),
                .ARB_TYPE_ROUND_ROBIN(1), .ARB_LSB_HIGH_PRIORITY(1)
            ) candidate (
                .clk(clk), .rst(rst),
                .s_axis_tdata(s_data), .s_axis_tkeep({PORTS*KEEP_WIDTH{1'b1}}),
                .s_axis_tvalid(s_valid & {PORTS{!rst}}), .s_axis_tready(input_ready), .s_axis_tlast(s_last),
                .s_axis_tid(source_id), .s_axis_tdest({PORTS{1'b0}}), .s_axis_tuser({PORTS{1'b0}}),
                .m_axis_tdata(m_data), .m_axis_tkeep(), .m_axis_tvalid(output_valid),
                .m_axis_tready(m_ready && !rst), .m_axis_tlast(m_last),
                .m_axis_tid(m_source), .m_axis_tdest(), .m_axis_tuser()
            );
        end else if (EXTERNAL == 1) begin : external_candidate
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
