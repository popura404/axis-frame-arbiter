`timescale 1ns/1ps
`default_nettype none

// Common source fixture for the RFNoC comparison. UHD implementations are
// fetched unchanged at the commit and license recorded in external_uhd.json.
// A one-sample, non-EOB packet followed by a missing sample makes the real
// radio core produce an underrun event. No event FIFO or CDC is modeled here.
module rfnoc_source #(
    parameter integer SOURCE_ID = 0
) (
    input  wire        radio_clk,
    input  wire        ctrl_clk,
    input  wire        radio_rst,
    input  wire        ctrl_rst,
    input  wire        sample_valid,
    output wire        sample_ready,
    input  wire        radio_strobe,
    input  wire [63:0] radio_time,
    output wire        radio_running,
    output wire        request_valid,
    output wire        request_ack,
    output wire [63:0] request_time,
    output wire [31:0] m_data,
    output wire        m_last,
    output wire        m_valid,
    input  wire        m_ready,
    input  wire [31:0] s_data,
    input  wire        s_last,
    input  wire        s_valid,
    output wire        s_ready
);
    wire cfg_wr, cfg_rd, cfg_ack;
    wire [19:0] cfg_addr;
    wire [31:0] cfg_data, cfg_response;
    wire [19:0] req_addr;
    wire [31:0] req_data;
    wire req_has_time;
    wire [9:0] req_port, req_remote_port;
    wire [15:0] req_remote_epid;
    // Read-only observation boundary between the existing CDC and packet gate.
    wire [31:0] gate_data;
    wire gate_last, gate_valid, gate_ready;

    radio_tx_core #(.SAMP_W(32), .NSPC(1)) radio (
        .radio_clk(radio_clk), .radio_rst(radio_rst),
        .s_ctrlport_req_wr(cfg_wr), .s_ctrlport_req_rd(cfg_rd),
        .s_ctrlport_req_addr(cfg_addr), .s_ctrlport_req_data(cfg_data),
        .s_ctrlport_resp_ack(cfg_ack), .s_ctrlport_resp_data(cfg_response),
        .m_ctrlport_req_wr(request_valid), .m_ctrlport_req_addr(req_addr),
        .m_ctrlport_req_data(req_data), .m_ctrlport_req_has_time(req_has_time),
        .m_ctrlport_req_time(request_time), .m_ctrlport_req_portid(req_port),
        .m_ctrlport_req_rem_epid(req_remote_epid),
        .m_ctrlport_req_rem_portid(req_remote_port),
        .m_ctrlport_resp_ack(request_ack),
        .radio_time(radio_time), .radio_tx_data(),
        .radio_tx_stb(radio_strobe), .radio_tx_running(radio_running),
        .s_axis_tdata(32'b0), .s_axis_tlast(1'b1),
        .s_axis_tvalid(sample_valid), .s_axis_tready(sample_ready),
        .s_axis_ttimestamp(64'b0), .s_axis_thas_time(1'b0), .s_axis_teob(1'b0)
    );

    // Same endpoint options as noc_shell_radio's default control path:
    // 512-word slave buffer, 2-word requested output buffer, both directions,
    // asynchronous clocks and normal remote write ACKs. In the frozen UHD
    // 7-series backend each async FIFO rounds its storage up to 32 words.
    ctrlport_endpoint #(
        .THIS_PORTID(SOURCE_ID), .SYNC_CLKS(0),
        .AXIS_CTRL_MST_EN(1), .AXIS_CTRL_SLV_EN(1),
        .SLAVE_FIFO_SIZE(9), .CTRL_OUT_FIFO_SIZE(1), .SKIP_WR_ACK_WAIT(0)
    ) endpoint (
        .rfnoc_ctrl_clk(ctrl_clk), .rfnoc_ctrl_rst(ctrl_rst),
        .ctrlport_clk(radio_clk), .ctrlport_rst(radio_rst),
        .s_rfnoc_ctrl_tdata(s_data), .s_rfnoc_ctrl_tlast(s_last),
        .s_rfnoc_ctrl_tvalid(s_valid), .s_rfnoc_ctrl_tready(s_ready),
        .m_rfnoc_ctrl_tdata(gate_data), .m_rfnoc_ctrl_tlast(gate_last),
        .m_rfnoc_ctrl_tvalid(gate_valid), .m_rfnoc_ctrl_tready(gate_ready),
        .m_ctrlport_req_wr(cfg_wr), .m_ctrlport_req_rd(cfg_rd),
        .m_ctrlport_req_addr(cfg_addr), .m_ctrlport_req_data(cfg_data),
        .m_ctrlport_req_byte_en(), .m_ctrlport_req_has_time(),
        .m_ctrlport_req_time(), .m_ctrlport_resp_ack(cfg_ack),
        .m_ctrlport_resp_status(2'b00), .m_ctrlport_resp_data(cfg_response),
        .s_ctrlport_req_wr(request_valid), .s_ctrlport_req_rd(1'b0),
        .s_ctrlport_req_addr(req_addr), .s_ctrlport_req_portid(req_port),
        .s_ctrlport_req_rem_epid(req_remote_epid),
        .s_ctrlport_req_rem_portid(req_remote_port),
        .s_ctrlport_req_data(req_data), .s_ctrlport_req_byte_en(4'b1111),
        .s_ctrlport_req_has_time(req_has_time), .s_ctrlport_req_time(request_time),
        .s_ctrlport_resp_ack(request_ack), .s_ctrlport_resp_status(),
        .s_ctrlport_resp_data()
    );

    // Same terminal ingress gate as torus_2d_dor_router_single_sw, with the
    // control-crossbar template's TERM_BUFF_SIZE=5. Keep the default metadata
    // buffering policy as well as the 32-word data RAM on both candidates.
    axi_packet_gate #(
        .WIDTH(32), .SIZE(5), .USE_AS_BUFF(0), .MIN_PKT_SIZE(0)
    ) terminal_gate (
        .clk(ctrl_clk), .reset(ctrl_rst), .clear(1'b0),
        .i_tdata(gate_data), .i_tlast(gate_last), .i_terror(1'b0),
        .i_tvalid(gate_valid), .i_tready(gate_ready),
        .o_tdata(m_data), .o_tlast(m_last), .o_tvalid(m_valid), .o_tready(m_ready)
    );
endmodule

`default_nettype wire
