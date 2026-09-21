`timescale 1ns/1ps
// Frame events and pixels must share clk. frame_end follows the last pixel.
module gray_bowl_detector #(
    parameter EXPECTED_PIXELS = 19200
)(
    input wire clk, rst_n,
    input wire frame_start, frame_abort, frame_end, pixel_valid,
    input wire [7:0] pixel_gray, threshold,
    input wire [31:0] frame_id,
    output reg active, result_valid, error,
    output reg [1:0] bowl_state, // 0=no absence, 1=absence, 2=tie/unknown
    output reg [31:0] result_frame_id, pixels_total, pixels_bright
);
    reg [31:0] total, bright, current_id;
    reg [7:0] threshold_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0; result_valid <= 0; error <= 0; bowl_state <= 2;
            result_frame_id <= 0; pixels_total <= 0; pixels_bright <= 0;
            total <= 0; bright <= 0; current_id <= 0; threshold_r <= 0;
        end else if (frame_abort) begin
            active <= 0; result_valid <= 0; error <= 1;
            total <= 0; bright <= 0;
        end else if (frame_start) begin
            active <= 1; error <= 0; total <= 0; bright <= 0;
            current_id <= frame_id; threshold_r <= threshold;
            // Keep previous snapshot while collecting a new frame.
        end else if (active) begin
            if (frame_end) begin
                active <= 0;
                if (total != EXPECTED_PIXELS || pixel_valid) begin
                    result_valid <= 0; error <= 1;
                end else begin
                    result_valid <= 1; error <= 0;
                    result_frame_id <= current_id;
                    pixels_total <= total; pixels_bright <= bright;
                    if (bright > total-bright) bowl_state <= 1;
                    else if (bright < total-bright) bowl_state <= 0;
                    else bowl_state <= 2;
                end
            end else if (pixel_valid) begin
                if (total >= EXPECTED_PIXELS) begin
                    active <= 0; result_valid <= 0; error <= 1;
                end else begin
                    total <= total + 1;
                    if (pixel_gray > threshold_r) bright <= bright + 1;
                end
            end
        end
    end
endmodule
