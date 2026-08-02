`timescale 1ns/1ps

module axis_to_raster_tb;

    localparam integer ACTIVE_WIDTH = 4;
    localparam integer ACTIVE_HEIGHT = 3;
    localparam integer H_TOTAL = 7;
    localparam integer V_TOTAL = 5;
    localparam time CLK_PERIOD = 10ns;
    localparam logic [10:0] ACTIVE_WIDTH_VALUE = ACTIVE_WIDTH[10:0];
    localparam logic [9:0] ACTIVE_HEIGHT_VALUE = ACTIVE_HEIGHT[9:0];
    localparam logic [10:0] H_TOTAL_VALUE = H_TOTAL[10:0];
    localparam logic [9:0] V_TOTAL_VALUE = V_TOTAL[9:0];
    localparam logic [10:0] LAST_RASTER_X = H_TOTAL_VALUE - 1'b1;
    localparam logic [9:0] LAST_RASTER_Y = V_TOTAL_VALUE - 1'b1;

    logic pix_clk;
    logic pix_reset;

    logic [23:0] s_axis_tdata;
    logic s_axis_tvalid;
    logic s_axis_tready;
    logic s_axis_tuser;
    logic s_axis_tlast;

    logic [10:0] h_count;
    logic [9:0] v_count;
    logic active_video;
    logic [23:0] raster_rgb;

    logic status_frame_locked;
    logic status_overflow;
    logic status_malformed_line;
    logic status_underflow;
    logic status_black_fallback;

    logic input_line_open_q;
    integer input_line_column_q;

    axis_to_raster #(
        .ACTIVE_WIDTH(ACTIVE_WIDTH),
        .ACTIVE_HEIGHT(ACTIVE_HEIGHT),
        .H_TOTAL(H_TOTAL),
        .V_TOTAL(V_TOTAL)
    ) dut (
        .pix_clk,
        .pix_reset,
        .s_axis_tdata,
        .s_axis_tvalid,
        .s_axis_tready,
        .s_axis_tuser,
        .s_axis_tlast,
        .h_count,
        .v_count,
        .active_video,
        .raster_rgb,
        .status_frame_locked,
        .status_overflow,
        .status_malformed_line,
        .status_underflow,
        .status_black_fallback
    );

    always #(CLK_PERIOD / 2) pix_clk = !pix_clk;

    assign active_video = !pix_reset
        && (h_count < ACTIVE_WIDTH_VALUE)
        && (v_count < ACTIVE_HEIGHT_VALUE);

    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            h_count <= '0;
            v_count <= '0;
        end else if (h_count == LAST_RASTER_X) begin
            h_count <= '0;

            if (v_count == LAST_RASTER_Y) begin
                v_count <= '0;
            end else begin
                v_count <= v_count + 1'b1;
            end
        end else begin
            h_count <= h_count + 1'b1;
        end
    end

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $fatal(1, "CHECK FAILED: %s", message);
        end
    endtask

    function automatic logic [23:0] pixel_value(
        input logic [23:0] base,
        input integer line_index,
        input integer column_index
    );
        pixel_value = base + 24'(line_index * ACTIVE_WIDTH + column_index);
    endfunction

    task automatic send_line(
        input logic [23:0] base,
        input integer line_index,
        input logic line_sof,
        input logic inject_early_tlast
    );
        for (integer column_index = 0; column_index < ACTIVE_WIDTH; column_index++) begin
            @(negedge pix_clk);
            s_axis_tdata = pixel_value(base, line_index, column_index);
            s_axis_tvalid = 1'b1;
            s_axis_tuser = line_sof && (column_index == 0);
            s_axis_tlast = (column_index == ACTIVE_WIDTH - 1)
                || (inject_early_tlast && (column_index == 1));

            do begin
                @(posedge pix_clk);
            end while (!s_axis_tready);
        end

        @(negedge pix_clk);
        s_axis_tvalid = 1'b0;
        s_axis_tuser = 1'b0;
        s_axis_tlast = 1'b0;
    endtask

    task automatic send_frame(
        input logic [23:0] base,
        input logic inject_early_tlast
    );
        for (integer line_index = 0; line_index < ACTIVE_HEIGHT; line_index++) begin
            send_line(base, line_index, line_index == 0, inject_early_tlast && (line_index == 1));
        end
    endtask

    task automatic check_first_locked_line(input logic [23:0] base);
        wait (status_frame_locked);

        for (integer column_index = 0; column_index < ACTIVE_WIDTH; column_index++) begin
            @(negedge pix_clk);
            check(v_count == 0, "first locked line had the wrong raster line index");
            check(h_count == column_index[10:0], "first locked line changed or skipped a column");
            check(raster_rgb == pixel_value(base, 0, column_index), "first locked line pixel mismatch");
        end
    endtask

    task automatic check_locked_frame(input logic [23:0] base);
        wait (status_frame_locked);

        for (integer line_index = 0; line_index < ACTIVE_HEIGHT; line_index++) begin
            for (integer column_index = 0; column_index < ACTIVE_WIDTH; column_index++) begin
                @(negedge pix_clk);
                check(status_frame_locked, "frame lock was lost during a complete frame");
                check(v_count == line_index[9:0], "locked frame changed or skipped a line");
                check(h_count == column_index[10:0], "locked frame changed or skipped a column");
                check(raster_rgb == pixel_value(base, line_index, column_index), "locked frame pixel mismatch");
            end

            // Skip horizontal blanking before checking the next active line.
            if (line_index != ACTIVE_HEIGHT - 1) begin
                wait ((h_count == 0) && (v_count == (line_index[9:0] + 1'b1)));
            end
        end
    endtask

    // External form of the line-atomic ready property: after accepting the
    // first pixel, ready must stay high until the configured final pixel.
    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            input_line_open_q <= 1'b0;
            input_line_column_q <= 0;
        end else begin
            if (input_line_open_q) begin
                check(s_axis_tready, "s_axis_tready dropped in the middle of a line");
            end

            if (s_axis_tvalid && s_axis_tready) begin
                if (!input_line_open_q) begin
                    input_line_open_q <= (ACTIVE_WIDTH > 1);
                    input_line_column_q <= 1;
                end else if (input_line_column_q == ACTIVE_WIDTH - 1) begin
                    input_line_open_q <= 1'b0;
                    input_line_column_q <= 0;
                end else begin
                    input_line_column_q <= input_line_column_q + 1;
                end
            end
        end
    end

    // Any unlocked active raster pixel must be deterministic black.
    always @(negedge pix_clk) begin
        if (!pix_reset && active_video && !status_frame_locked) begin
            check(raster_rgb == 24'h000000, "unlocked raster output was not black");
        end
    end

    initial begin
        pix_clk = 1'b0;
        pix_reset = 1'b1;
        s_axis_tdata = '0;
        s_axis_tvalid = 1'b0;
        s_axis_tuser = 1'b0;
        s_axis_tlast = 1'b0;
        h_count = '0;
        v_count = '0;
        input_line_open_q = 1'b0;
        input_line_column_q = 0;

        repeat (4) @(posedge pix_clk);
        @(negedge pix_clk);
        pix_reset = 1'b0;

        check(!status_underflow, "startup asserted underflow before first lock");
        check(!status_black_fallback, "startup asserted fallback before first lock");

        // One complete SOF line is enough to acquire at the next frame boundary,
        // but the absent second line must then force deterministic recovery.
        fork
            send_line(24'h001000, 0, 1'b1, 1'b0);
            check_first_locked_line(24'h001000);
        join

        wait (!status_frame_locked);
        #1ps;
        check(status_underflow, "missing line did not assert sticky underflow");
        check(status_black_fallback, "missing line did not assert sticky fallback");
        check(!status_overflow, "legal traffic asserted overflow");

        // A fresh SOF must resynchronize the adapter. Early TLAST is reported,
        // while the accepted-pixel count still defines the stored line length.
        fork
            send_frame(24'h002000, 1'b1);
            check_locked_frame(24'h002000);
        join

        check(status_frame_locked, "adapter failed to reacquire on a fresh SOF frame");
        check(status_malformed_line, "early TLAST did not assert malformed-line status");
        check(status_underflow, "underflow status was not sticky after reacquisition");
        check(status_black_fallback, "fallback status was not sticky after reacquisition");
        check(!status_overflow, "recovery traffic asserted overflow");

        $display("axis_to_raster_tb: PASS");
        $finish;
    end

    initial begin
        #20us;
        $fatal(1, "axis_to_raster_tb timed out");
    end

endmodule
