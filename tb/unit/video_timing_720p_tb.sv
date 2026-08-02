`timescale 1ns/1ps

module video_timing_720p_tb;

    localparam time CLK_PERIOD = 10ns;

    localparam integer H_ACTIVE = 1280;
    localparam integer H_FRONT_PORCH = 110;
    localparam integer H_SYNC_WIDTH = 40;
    localparam integer H_TOTAL = 1650;

    localparam integer V_ACTIVE = 720;
    localparam integer V_FRONT_PORCH = 5;
    localparam integer V_SYNC_WIDTH = 5;
    localparam integer V_TOTAL = 750;

    localparam integer H_SYNC_START = H_ACTIVE + H_FRONT_PORCH;
    localparam integer H_SYNC_END = H_SYNC_START + H_SYNC_WIDTH;
    localparam integer V_SYNC_START = V_ACTIVE + V_FRONT_PORCH;
    localparam integer V_SYNC_END = V_SYNC_START + V_SYNC_WIDTH;

    logic pix_clk;
    logic pix_reset;
    logic [10:0] h_count;
    logic [9:0] v_count;
    logic active_video;
    logic hsync;
    logic vsync;

    integer active_pixel_count;
    integer hsync_pixel_count;
    integer vsync_pixel_count;

    video_timing_720p dut (
        .pix_clk,
        .pix_reset,
        .h_count,
        .v_count,
        .active_video,
        .hsync,
        .vsync
    );

    always #(CLK_PERIOD / 2) pix_clk = !pix_clk;

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $fatal(1, "CHECK FAILED: %s", message);
        end
    endtask

    initial begin
        pix_clk = 1'b0;
        pix_reset = 1'b1;
        active_pixel_count = 0;
        hsync_pixel_count = 0;
        vsync_pixel_count = 0;

        repeat (2) @(posedge pix_clk);
        #1ps;
        check(h_count == 0 && v_count == 0, "counters did not clear during reset");
        check(!active_video && !hsync && !vsync, "timing outputs were active during reset");

        @(negedge pix_clk);
        pix_reset = 1'b0;
        #1ps;

        for (integer expected_y = 0; expected_y < V_TOTAL; expected_y++) begin
            for (integer expected_x = 0; expected_x < H_TOTAL; expected_x++) begin
                check(h_count == expected_x[10:0], "horizontal coordinate mismatch");
                check(v_count == expected_y[9:0], "vertical coordinate mismatch");

                check(
                    active_video == ((expected_x < H_ACTIVE) && (expected_y < V_ACTIVE)),
                    "active-video region mismatch"
                );
                check(
                    hsync == ((expected_x >= H_SYNC_START) && (expected_x < H_SYNC_END)),
                    "horizontal-sync interval mismatch"
                );
                check(
                    vsync == ((expected_y >= V_SYNC_START) && (expected_y < V_SYNC_END)),
                    "vertical-sync interval mismatch"
                );

                if (active_video) begin
                    active_pixel_count++;
                end
                if (hsync) begin
                    hsync_pixel_count++;
                end
                if (vsync) begin
                    vsync_pixel_count++;
                end

                @(posedge pix_clk);
                #1ps;
            end
        end

        check(h_count == 0 && v_count == 0, "raster did not wrap after exactly one frame");
        check(
            active_pixel_count == H_ACTIVE * V_ACTIVE,
            "active-pixel count was not 1280x720"
        );
        check(
            hsync_pixel_count == H_SYNC_WIDTH * V_TOTAL,
            "HSYNC was not high for 40 pixels on every raster line"
        );
        check(
            vsync_pixel_count == V_SYNC_WIDTH * H_TOTAL,
            "VSYNC was not high for five complete raster lines"
        );

        // Move into HSYNC, then assert reset between clock edges. Outputs must
        // blank immediately and counters must clear on the next pixel edge.
        repeat (H_SYNC_START) begin
            @(posedge pix_clk);
            #1ps;
        end
        check(hsync, "test did not reach the horizontal-sync interval");

        #(CLK_PERIOD / 4);
        pix_reset = 1'b1;
        #1ps;
        check(!active_video && !hsync && !vsync, "outputs did not blank when reset asserted");

        @(posedge pix_clk);
        #1ps;
        check(h_count == 0 && v_count == 0, "mid-frame reset did not clear both counters");

        $display("video_timing_720p_tb: PASS");
        $finish;
    end

endmodule
