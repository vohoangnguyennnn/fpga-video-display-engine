`timescale 1ns/1ps

module window_3x3_tb;

    import video_pkg::video_payload_t;

    localparam integer MAX_WIDTH = 8;
    localparam integer MAX_HEIGHT = 6;

    logic aclk;
    logic aresetn;

    video_payload_t s_axis_payload;
    logic s_axis_tvalid;
    logic s_axis_tready;
    logic [15:0] active_width;
    logic [15:0] active_height;

    logic [7:0] m_window_p00;
    logic [7:0] m_window_p01;
    logic [7:0] m_window_p02;
    logic [7:0] m_window_p10;
    logic [7:0] m_window_p11;
    logic [7:0] m_window_p12;
    logic [7:0] m_window_p20;
    logic [7:0] m_window_p21;
    logic [7:0] m_window_p22;
    logic m_window_valid;
    logic m_window_ready;

    logic [71:0] expected_windows[$];
    logic [71:0] held_window;
    logic output_was_stalled;
    integer cycle_index;
    integer accepted_count;
    integer output_count;

    window_3x3 #(
        .MAX_WIDTH(MAX_WIDTH),
        .MAX_HEIGHT(MAX_HEIGHT)
    ) dut (
        .aclk,
        .aresetn,
        .s_axis_payload,
        .s_axis_tvalid,
        .s_axis_tready,
        .active_width,
        .active_height,
        .m_window_p00,
        .m_window_p01,
        .m_window_p02,
        .m_window_p10,
        .m_window_p11,
        .m_window_p12,
        .m_window_p20,
        .m_window_p21,
        .m_window_p22,
        .m_window_valid,
        .m_window_ready
    );

    initial begin
        aclk = 1'b0;
        forever #5 aclk = ~aclk;
    end

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $display("FAIL: %s", message);
            $fatal(1);
        end
    endtask

    function automatic logic [7:0] pixel_value(
        input integer base,
        input integer width,
        input integer row,
        input integer column
    );
        logic [31:0] value;
        logic [23:0] _unused_high;
        begin
            value = base + (row * width) + column;
            {_unused_high, pixel_value} = value;
        end
    endfunction

    function automatic logic [71:0] expected_window(
        input integer base,
        input integer width,
        input integer height,
        input integer row,
        input integer column
    );
        begin
            if (
                (width < 3)
                || (height < 3)
                || (row == 0)
                || (row == (height - 1))
                || (column == 0)
                || (column == (width - 1))
            ) begin
                expected_window = 72'd0;
            end else begin
                expected_window = {
                    pixel_value(base, width, row - 1, column - 1),
                    pixel_value(base, width, row - 1, column),
                    pixel_value(base, width, row - 1, column + 1),
                    pixel_value(base, width, row, column - 1),
                    pixel_value(base, width, row, column),
                    pixel_value(base, width, row, column + 1),
                    pixel_value(base, width, row + 1, column - 1),
                    pixel_value(base, width, row + 1, column),
                    pixel_value(base, width, row + 1, column + 1)
                };
            end
        end
    endfunction

    function automatic video_payload_t make_payload(
        input logic [7:0] gray,
        input logic sof,
        input logic eol,
        input logic eof,
        input logic border
    );
        video_payload_t payload;
        begin
            payload.rgb = {gray, gray, gray};
            payload.gray = gray;
            payload.sof = sof;
            payload.eol = eol;
            payload.eof = eof;
            payload.border = border;
            return payload;
        end
    endfunction

    function automatic logic [71:0] current_window;
        begin
            current_window = {
                m_window_p00,
                m_window_p01,
                m_window_p02,
                m_window_p10,
                m_window_p11,
                m_window_p12,
                m_window_p20,
                m_window_p21,
                m_window_p22
            };
        end
    endfunction

    task automatic step(
        input logic source_valid,
        input video_payload_t source_payload,
        input logic sink_ready,
        output logic input_accepted
    );
        logic output_accepted;
        logic [71:0] expected;
        begin
            @(negedge aclk);
            s_axis_tvalid = source_valid;
            s_axis_payload = source_payload;
            m_window_ready = sink_ready;
            #1;

            input_accepted = source_valid && s_axis_tready;
            output_accepted = m_window_valid && sink_ready;

            if (output_was_stalled) begin
                check(m_window_valid, "window valid dropped while stalled");
                check(
                    current_window() === held_window,
                    "window changed while stalled"
                );
            end

            if (m_window_valid && !sink_ready) begin
                if (!output_was_stalled) begin
                    held_window = current_window();
                end
                output_was_stalled = 1'b1;
            end else begin
                output_was_stalled = 1'b0;
            end

            if (output_accepted) begin
                check(
                    expected_windows.size() != 0,
                    "window generator emitted an unexpected token"
                );
                expected = expected_windows.pop_front();
                check(
                    current_window() === expected,
                    "window contents or output ordering mismatch"
                );
                output_count = output_count + 1;
            end

            if (input_accepted) begin
                accepted_count = accepted_count + 1;
            end

            @(posedge aclk);
            #1;
            cycle_index = cycle_index + 1;
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge aclk);
            aresetn = 1'b0;
            s_axis_payload = '0;
            s_axis_tvalid = 1'b0;
            active_width = 16'd0;
            active_height = 16'd0;
            m_window_ready = 1'b0;
            expected_windows.delete();
            output_was_stalled = 1'b0;
            cycle_index = 0;
            accepted_count = 0;
            output_count = 0;

            repeat (2) @(posedge aclk);
            #1;
            check(!m_window_valid, "window valid remained asserted after reset");
            check(s_axis_tready, "window input was not ready after reset");

            @(negedge aclk);
            aresetn = 1'b1;
            #1;
        end
    endtask

    task automatic enqueue_expected_frame(
        input integer base,
        input integer width,
        input integer height
    );
        integer row;
        integer column;
        begin
            for (row = 0; row < height; row = row + 1) begin
                for (column = 0; column < width; column = column + 1) begin
                    expected_windows.push_back(
                        expected_window(base, width, height, row, column)
                    );
                end
            end
        end
    endtask

    task automatic send_frame(
        input integer base,
        input integer width,
        input integer height,
        input logic insert_bubbles,
        input logic apply_backpressure
    );
        integer row;
        integer column;
        integer linear_index;
        logic accepted;
        logic sink_ready;
        video_payload_t payload;
        video_payload_t idle_payload;
        begin
            active_width = width[15:0];
            active_height = height[15:0];
            idle_payload = '0;
            linear_index = 0;

            for (row = 0; row < height; row = row + 1) begin
                for (column = 0; column < width; column = column + 1) begin
                    payload = make_payload(
                        pixel_value(base, width, row, column),
                        (row == 0) && (column == 0),
                        column == (width - 1),
                        (row == (height - 1))
                            && (column == (width - 1)),
                        (row == 0)
                            || (row == (height - 1))
                            || (column == 0)
                            || (column == (width - 1))
                    );

                    if (insert_bubbles && ((linear_index % 5) == 2)) begin
                        sink_ready =
                            !apply_backpressure
                            || ((cycle_index % 4) != 0);
                        step(1'b0, idle_payload, sink_ready, accepted);
                    end

                    accepted = 1'b0;
                    while (!accepted) begin
                        sink_ready =
                            !apply_backpressure
                            || (
                                ((cycle_index % 4) != 0)
                                && ((cycle_index % 9) != 0)
                            );
                        step(1'b1, payload, sink_ready, accepted);
                    end

                    if (!apply_backpressure) begin
                        check(
                            accepted,
                            "ready sink did not accept a continuous input beat"
                        );
                    end
                    linear_index = linear_index + 1;
                end
            end
        end
    endtask

    task automatic wait_for_outputs(input integer target_count);
        integer guard;
        logic _unused_accepted;
        video_payload_t idle_payload;
        begin
            idle_payload = '0;
            guard = 0;
            while (output_count < target_count) begin
                step(1'b0, idle_payload, 1'b1, _unused_accepted);
                guard = guard + 1;
                check(guard < 128, "window output did not finish draining");
            end
        end
    endtask

    video_payload_t payload;
    logic accepted;
    integer target_count;
    integer first_frame_target;

    initial begin
        aresetn = 1'b0;
        s_axis_payload = '0;
        s_axis_tvalid = 1'b0;
        active_width = 16'd0;
        active_height = 16'd0;
        m_window_ready = 1'b0;
        output_was_stalled = 1'b0;
        cycle_index = 0;
        accepted_count = 0;
        output_count = 0;

        // 3x3 minimum: only the center window is non-zero.
        reset_dut();
        enqueue_expected_frame(1, 3, 3);
        target_count = 9;
        send_frame(1, 3, 3, 1'b0, 1'b0);
        wait_for_outputs(target_count);
        check(accepted_count == 9, "3x3 input count mismatch");
        check(expected_windows.size() == 0, "3x3 output count mismatch");
        check(!m_window_valid, "3x3 emitted an extra window");

        // 4x4 exercises both bank rotations and same-address read-before-write.
        enqueue_expected_frame(20, 4, 4);
        target_count = output_count + 16;
        send_frame(20, 4, 4, 1'b0, 1'b0);
        wait_for_outputs(target_count);
        check(expected_windows.size() == 0, "4x4 output count mismatch");
        check(!m_window_valid, "4x4 emitted an extra window");

        // Tiny 2x2 frames are legal and all four windows must be zero.
        enqueue_expected_frame(80, 2, 2);
        target_count = output_count + 4;
        send_frame(80, 2, 2, 1'b0, 1'b0);
        wait_for_outputs(target_count);
        check(expected_windows.size() == 0, "2x2 output count mismatch");

        // Bubbles and downstream stalls must not alter windows or RAM updates.
        reset_dut();
        enqueue_expected_frame(100, 5, 4);
        target_count = 20;
        send_frame(100, 5, 4, 1'b1, 1'b1);
        wait_for_outputs(target_count);
        check(accepted_count == 20, "stalled frame input count mismatch");
        check(expected_windows.size() == 0, "stalled frame output count mismatch");

        // Hold the next frame's SOF while the prior frame drains. It cannot be
        // accepted until the final prior window has transferred.
        reset_dut();
        enqueue_expected_frame(150, 3, 3);
        first_frame_target = 9;
        send_frame(150, 3, 3, 1'b0, 1'b0);

        enqueue_expected_frame(200, 1, 1);
        active_width = 16'd1;
        active_height = 16'd1;
        payload = make_payload(
            pixel_value(200, 1, 0, 0),
            1'b1,
            1'b1,
            1'b1,
            1'b1
        );

        repeat (3) begin
            step(1'b1, payload, 1'b0, accepted);
            check(!accepted, "next SOF was accepted during prior-frame drain");
        end

        accepted = 1'b0;
        while (!accepted) begin
            step(1'b1, payload, 1'b1, accepted);
        end
        check(
            output_count == first_frame_target,
            "next SOF was accepted before the prior final output"
        );

        target_count = first_frame_target + 1;
        wait_for_outputs(target_count);
        check(expected_windows.size() == 0, "back-to-back frame count mismatch");
        check(!m_window_valid, "back-to-back test emitted an extra window");

        $display("window_3x3_tb: PASS");
        $finish;
    end

endmodule
