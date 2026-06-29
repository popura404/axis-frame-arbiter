`timescale 1ns/1ps
// Register the winner before presenting output. Empty mid-frame retains grant.
module frame_arbiter (
    input wire clk, input wire rst, input wire mode_rr,
    input wire [3:0] available, input wire frame_done,
    output reg active, output reg [1:0] source
);
    reg rr;
    reg [1:0] cursor;
    reg found;
    reg [1:0] candidate, index;
    integer offset;
    always @* begin
        found = 0;
        candidate = 0;
        index = 0;
        for (offset = 0; offset < 4; offset = offset + 1) begin
            index = rr ? (cursor + offset) : offset;
            if (!found && available[index]) begin
                found = 1;
                candidate = index;
            end
        end
    end
    always @(posedge clk) begin
        if (rst) begin
            rr <= mode_rr;
            cursor <= 0;
            active <= 0;
            source <= 0;
        end else if (!active) begin
            if (found) begin
                source <= candidate;
                active <= 1;
            end
        end else if (frame_done) begin
            active <= 0;
            cursor <= source + 2'd1;
        end
    end
endmodule
