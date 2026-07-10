`timescale 1ns/1ps
// Derive the expected payload from counters, independently of the arbiter/FIFOs.
// Counters wrap modulo 2^32; frame tags wrap modulo 2^24. Reset starts an epoch.
module sink_checker (
    input  wire         clk,
    input  wire         rst,
    input  wire [31:0]  data,
    input  wire         last,
    input  wire [1:0]   source,
    input  wire         valid,
    input  wire         ready,
    output reg  [31:0]  words,
    output reg  [127:0] frames,
    output reg  [31:0]  errors
);
    reg [23:0] next_frame [0:3];
    reg [3:0] next_beat;
    reg [1:0] frame_source;
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            words <= 0;
            frames <= 0;
            errors <= 0;
            next_beat <= 0;
            frame_source <= 0;
            for (i = 0; i < 4; i = i + 1)
                next_frame[i] <= 0;
        end else if (valid && ready) begin
            words <= words + 1'b1;
            if (data != {source, 2'b00, next_frame[source], next_beat} ||
                last != (next_beat == 4'd15) ||
                (next_beat != 0 && source != frame_source))
                errors <= errors + 1'b1;
            if (next_beat == 0)
                frame_source <= source;
            next_beat <= next_beat + 1'b1;
            if (next_beat == 4'd15)
                next_frame[source] <= next_frame[source] + 1'b1;
            if (last)
                frames[source*32 +: 32] <= frames[source*32 +: 32] + 1'b1;
        end
    end
endmodule
