`timescale 1ns/1ps

// Behavioral stand-in for the generated Clocking Wizard. This file is used
// only by RTL simulation; Vivado synthesis uses the video_clk_wiz IP.
module video_clk_wiz (
    input logic clk_in1,
    input logic reset,

    output logic locked,
    output logic pix_clk,
    output logic tmds_clk_5x
);

    logic [1:0] lock_count_q;
    logic locked_q;
    logic force_lock_loss;

    assign pix_clk = clk_in1;
    assign locked = locked_q && !force_lock_loss;

    initial begin
        lock_count_q = '0;
        locked_q = 1'b0;
        tmds_clk_5x = 1'b0;
        force_lock_loss = 1'b0;
    end

    always #2ns tmds_clk_5x = !tmds_clk_5x;

    always_ff @(posedge clk_in1 or posedge reset) begin
        if (reset || force_lock_loss) begin
            lock_count_q <= '0;
            locked_q <= 1'b0;
        end else if (!locked_q) begin
            if (lock_count_q == 2) begin
                locked_q <= 1'b1;
            end else begin
                lock_count_q <= lock_count_q + 1'b1;
            end
        end
    end

endmodule
