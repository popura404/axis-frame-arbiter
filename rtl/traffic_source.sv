`timescale 1ns/1ps
// Stop at a frame boundary, including an already offered but stalled first beat.
module traffic_source #(
    parameter [1:0] SOURCE_ID = 2'd0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        run,
    output wire [31:0] data,
    output wire        last,
    output reg         valid,
    input  wire        ready
);
    reg [23:0] frame_number;
    reg [3:0] beat_number;

    assign data = {SOURCE_ID, 2'b00, frame_number, beat_number};
    assign last = (beat_number == 4'd15);

    always @(posedge clk) begin
        if (rst) begin
            frame_number <= 0;
            beat_number <= 0;
            valid <= 0;
        end else if (!valid) begin
            if (run)
                valid <= 1;
        end else if (ready) begin
            if (last) begin
                frame_number <= frame_number + 1'b1;
                beat_number <= 0;
                valid <= run;
            end else begin
                beat_number <= beat_number + 1'b1;
            end
        end
    end
endmodule
