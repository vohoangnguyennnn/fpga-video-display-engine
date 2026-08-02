`timescale 1ns/1ps

module video_test_pattern_tb;

    localparam time CLK_PERIOD = 10ns;
    localparam integer FRAME_WIDTH = 1280;
    localparam integer FRAME_HEIGHT = 720;
    localparam integer MOTION_SIZE = 64;
    localparam logic [23:0] MOTION_COLOR = 24'hFF8000;

    logic pix_clk;
    logic pix_reset;
    logic [23:0] m_axis_tdata;
    logic m_axis_tvalid;
    logic m_axis_tready;
    logic m_axis_tuser;
    logic m_axis_tlast;

    integer sof_count;
    integer eol_count;
    integer pixel_count;

    video_test_pattern dut (
        .pix_clk,
        .pix_reset,
        .m_axis_tdata,
        .m_axis_tvalid,
        .m_axis_tready,
        .m_axis_tuser,
        .m_axis_tlast
    );

    always #(CLK_PERIOD / 2) pix_clk = !pix_clk;

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $fatal(1, "CHECK FAILED: %s", message);
        end
    endtask

    function automatic logic [23:0] expected_pixel(
        input integer x,
        input integer y,
        input integer motion_x
    );
        logic [7:0] ramp;
        integer bar_index;
        begin
            ramp = 8'(x / 5);
            expected_pixel = 24'h000000;

            if (y < 180) begin
                bar_index = x / 160;
                case (bar_index)
                    0: expected_pixel = 24'hFFFFFF;
                    1: expected_pixel = 24'hFFFF00;
                    2: expected_pixel = 24'h00FFFF;
                    3: expected_pixel = 24'h00FF00;
                    4: expected_pixel = 24'hFF00FF;
                    5: expected_pixel = 24'hFF0000;
                    6: expected_pixel = 24'h0000FF;
                    default: expected_pixel = 24'h000000;
                endcase
            end else if (y < 240) begin
                expected_pixel = {ramp, 16'h0000};
            end else if (y < 300) begin
                expected_pixel = {8'h00, ramp, 8'h00};
            end else if (y < 360) begin
                expected_pixel = {16'h0000, ramp};
            end else if (y < 540) begin
                expected_pixel = ((((x / 32) + (y / 32)) % 2) != 0) ?
                                 24'hFFFFFF : 24'h000000;
            end else begin
                expected_pixel = (((x + y) % 64) < 3) ?
                                 24'hFFFFFF : 24'h001020;
            end

            if ((x >= motion_x) &&
                (x < motion_x + MOTION_SIZE) &&
                (y >= 328) &&
                (y < 392)) begin
                expected_pixel = MOTION_COLOR;
            end
        end
    endfunction

    task automatic check_current_pixel(
        input integer expected_x,
        input integer expected_y,
        input integer expected_motion_x
    );
        check(m_axis_tvalid, "source valid dropped outside reset");
        check(
            m_axis_tuser == ((expected_x == 0) && (expected_y == 0)),
            "SOF marker mismatch"
        );
        check(m_axis_tlast == (expected_x == FRAME_WIDTH - 1), "EOL marker mismatch");
        check(
            m_axis_tdata == expected_pixel(expected_x, expected_y, expected_motion_x),
            "test-pattern pixel mismatch"
        );
    endtask

    initial begin
        pix_clk = 1'b0;
        pix_reset = 1'b1;
        m_axis_tready = 1'b0;
        sof_count = 0;
        eol_count = 0;
        pixel_count = 0;

        repeat (2) @(posedge pix_clk);
        #1ps;
        check(!m_axis_tvalid, "valid was asserted during reset");
        check(!m_axis_tuser && !m_axis_tlast, "markers were asserted during reset");
        check(m_axis_tdata == 0, "pixel output was not black during reset");

        @(negedge pix_clk);
        pix_reset = 1'b0;
        #1ps;
        check_current_pixel(0, 0, 0);

        // Hold the first SOF pixel stalled and prove the complete AXI payload
        // remains stable until it is accepted.
        repeat (5) begin
            @(posedge pix_clk);
            #1ps;
            check_current_pixel(0, 0, 0);
        end

        m_axis_tready = 1'b1;

        for (integer expected_y = 0; expected_y < FRAME_HEIGHT; expected_y++) begin
            for (integer expected_x = 0; expected_x < FRAME_WIDTH; expected_x++) begin
                check_current_pixel(expected_x, expected_y, 0);

                if (m_axis_tuser) begin
                    sof_count++;
                end
                if (m_axis_tlast) begin
                    eol_count++;
                end
                pixel_count++;

                @(posedge pix_clk);
                #1ps;
            end
        end

        check(pixel_count == FRAME_WIDTH * FRAME_HEIGHT, "frame pixel count mismatch");
        check(sof_count == 1, "frame did not contain exactly one SOF");
        check(eol_count == FRAME_HEIGHT, "frame did not contain one EOL per line");
        check_current_pixel(0, 0, 4);

        // In the next frame the square has moved from x=0 to x=4. Run to the
        // shape row and verify both the vacated and new leading-edge pixels.
        for (integer expected_y = 0; expected_y <= 328; expected_y++) begin
            integer line_limit;
            line_limit = (expected_y == 328) ? 4 : FRAME_WIDTH - 1;

            for (integer expected_x = 0; expected_x <= line_limit; expected_x++) begin
                check_current_pixel(expected_x, expected_y, 4);

                if ((expected_y == 328) && (expected_x == 0)) begin
                    check(m_axis_tdata != MOTION_COLOR, "moving square did not vacate x=0");
                end
                if ((expected_y == 328) && (expected_x == 4)) begin
                    check(m_axis_tdata == MOTION_COLOR, "moving square did not advance to x=4");
                end

                if (!((expected_y == 328) && (expected_x == 4))) begin
                    @(posedge pix_clk);
                    #1ps;
                end
            end
        end

        // Reset while stalled. The source must withdraw valid and restart from
        // a fresh SOF after reset release.
        m_axis_tready = 1'b0;
        #(CLK_PERIOD / 4);
        pix_reset = 1'b1;
        #1ps;
        check(!m_axis_tvalid, "valid remained asserted during mid-frame reset");
        check(!m_axis_tuser && !m_axis_tlast, "markers remained active during reset");
        check(m_axis_tdata == 0, "reset did not blank the pattern output");

        @(posedge pix_clk);
        @(negedge pix_clk);
        pix_reset = 1'b0;
        #1ps;
        check_current_pixel(0, 0, 0);

        $display("video_test_pattern_tb: PASS");
        $finish;
    end

endmodule
