`timescale 1ns/1ps
// Pinned verilog-axis reference; fetch with scripts/fetch_axis.py.
// FIFO_DEPTH is RAM beats, not total accepted-but-unconsumed capacity:
// per lane D+2 slots, plus 2 shared output/skid slots. No capacity equivalence
// to stream_arbiter is implied. FRAME_FIFO applies to legal fixed-16-beat frames.
module axis_external #(
    parameter integer PORTS = 4,
    parameter integer DATA_WIDTH = 32,
    parameter integer FIFO_DEPTH = 16,
    parameter integer FRAME_FIFO = 0
) (
    input  wire clk,
    input  wire rst,
    input  wire [PORTS*DATA_WIDTH-1:0] s_data,
    input  wire [PORTS-1:0] s_last,
    input  wire [PORTS-1:0] s_valid,
    output wire [PORTS-1:0] s_ready,
    output wire [DATA_WIDTH-1:0] m_data,
    output wire m_last,
    output wire m_valid,
    input  wire m_ready,
    output wire [$clog2(PORTS)-1:0] m_source
);
    localparam integer KEEP_WIDTH = DATA_WIDTH / 8;
    localparam integer SOURCE_WIDTH = $clog2(PORTS);
    wire [PORTS*DATA_WIDTH-1:0] fifo_data;
    wire [PORTS-1:0] fifo_last, fifo_valid, fifo_ready, input_ready;
    wire [PORTS*SOURCE_WIDTH-1:0] source_id;
    wire output_valid;

    assign s_ready = input_ready & {PORTS{!rst}};
    assign m_valid = output_valid && !rst;

    genvar lane;
    generate
        if ((PORTS != 2 && PORTS != 4 && PORTS != 8) ||
            (DATA_WIDTH != 32 && DATA_WIDTH != 64) ||
            (FIFO_DEPTH != 16 && FIFO_DEPTH != 64) ||
            (FRAME_FIFO != 0 && FRAME_FIFO != 1)) begin : unsupported_configuration
            EXTERNAL_AXIS_UNSUPPORTED_PARAMETERS invalid_configuration ();
        end
        for (lane = 0; lane < PORTS; lane = lane + 1) begin : inputs
            localparam [SOURCE_WIDTH-1:0] SOURCE_ID = lane;
            assign source_id[lane*SOURCE_WIDTH +: SOURCE_WIDTH] = SOURCE_ID;
            axis_fifo #(
                .DEPTH(FIFO_DEPTH), .DATA_WIDTH(DATA_WIDTH),
                .KEEP_ENABLE(0), .KEEP_WIDTH(KEEP_WIDTH), .LAST_ENABLE(1),
                .ID_ENABLE(0), .ID_WIDTH(1), .DEST_ENABLE(0), .DEST_WIDTH(1),
                .USER_ENABLE(0), .USER_WIDTH(1), .RAM_PIPELINE(0),
                .OUTPUT_FIFO_ENABLE(0), .FRAME_FIFO(FRAME_FIFO),
                .DROP_OVERSIZE_FRAME(0), .DROP_BAD_FRAME(0),
                .DROP_WHEN_FULL(0), .MARK_WHEN_FULL(0), .PAUSE_ENABLE(0)
            ) fifo (
                .clk(clk), .rst(rst),
                .s_axis_tdata(s_data[lane*DATA_WIDTH +: DATA_WIDTH]),
                .s_axis_tkeep({KEEP_WIDTH{1'b1}}),
                .s_axis_tvalid(s_valid[lane] && !rst), .s_axis_tready(input_ready[lane]),
                .s_axis_tlast(s_last[lane]), .s_axis_tid(1'b0),
                .s_axis_tdest(1'b0), .s_axis_tuser(1'b0),
                .m_axis_tdata(fifo_data[lane*DATA_WIDTH +: DATA_WIDTH]),
                .m_axis_tkeep(), .m_axis_tvalid(fifo_valid[lane]),
                .m_axis_tready(fifo_ready[lane]), .m_axis_tlast(fifo_last[lane]),
                .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
                .pause_req(1'b0), .pause_ack(), .status_depth(), .status_depth_commit(),
                .status_overflow(), .status_bad_frame(), .status_good_frame()
            );
        end
    endgenerate

    axis_arb_mux #(
        .S_COUNT(PORTS), .DATA_WIDTH(DATA_WIDTH),
        .KEEP_ENABLE(0), .KEEP_WIDTH(KEEP_WIDTH), .LAST_ENABLE(1),
        .ID_ENABLE(1), .S_ID_WIDTH(SOURCE_WIDTH), .M_ID_WIDTH(SOURCE_WIDTH),
        .UPDATE_TID(0), .DEST_ENABLE(0), .DEST_WIDTH(1),
        .USER_ENABLE(0), .USER_WIDTH(1),
        .ARB_TYPE_ROUND_ROBIN(1), .ARB_LSB_HIGH_PRIORITY(1)
    ) arbiter (
        .clk(clk), .rst(rst),
        .s_axis_tdata(fifo_data), .s_axis_tkeep({PORTS*KEEP_WIDTH{1'b1}}),
        .s_axis_tvalid(fifo_valid), .s_axis_tready(fifo_ready), .s_axis_tlast(fifo_last),
        .s_axis_tid(source_id), .s_axis_tdest({PORTS{1'b0}}), .s_axis_tuser({PORTS{1'b0}}),
        .m_axis_tdata(m_data), .m_axis_tkeep(), .m_axis_tvalid(output_valid),
        .m_axis_tready(m_ready && !rst), .m_axis_tlast(m_last),
        .m_axis_tid(m_source), .m_axis_tdest(), .m_axis_tuser()
    );
endmodule
