`timescale 1ns/1ps

module video_stream_core_tb;

    localparam integer MAX_WIDTH = 4;
    localparam integer MAX_HEIGHT = 4;
    localparam integer FRAME_WIDTH = 3;
    localparam integer FRAME_HEIGHT = 3;
    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam logic [15:0] MAX_WIDTH_VALUE = MAX_WIDTH[15:0];
    localparam logic [15:0] MAX_HEIGHT_VALUE = MAX_HEIGHT[15:0];
    localparam logic [15:0] FRAME_WIDTH_VALUE = FRAME_WIDTH[15:0];
    localparam logic [15:0] FRAME_HEIGHT_VALUE = FRAME_HEIGHT[15:0];

    localparam logic [1:0] MODE_PASSTHROUGH = 2'd0;
    localparam logic [1:0] MODE_GRAYSCALE = 2'd1;
    localparam logic [1:0] MODE_SOBEL_MAGNITUDE = 2'd2;
    localparam logic [1:0] MODE_BINARY_EDGE = 2'd3;

    typedef struct packed {
        logic [23:0] data;
        logic user_marker;
        logic last_marker;
    } expected_token_t;

    logic aclk;
    logic aresetn;

    logic [23:0] s_axis_tdata;
    logic s_axis_tvalid;
    logic s_axis_tready;
    logic s_axis_tuser;
    logic s_axis_tlast;

    logic [23:0] m_axis_tdata;
    logic m_axis_tvalid;
    logic m_axis_tready;
    logic m_axis_tuser;
    logic m_axis_tlast;

    logic [1:0] cfg_mode;
    logic [7:0] cfg_threshold;
    logic [15:0] cfg_frame_width;
    logic [15:0] cfg_frame_height;

    logic status_in_frame;
    logic status_protocol_error;

    expected_token_t expected_tokens[$];
    logic output_was_stalled;
    logic [23:0] held_output_data;
    logic held_output_user;
    logic held_output_last;
    integer cycle_index;
    integer input_count;
    integer output_count;

    video_stream_core #(
        .MAX_WIDTH(MAX_WIDTH),
        .MAX_HEIGHT(MAX_HEIGHT)
    ) dut (
        .aclk,
        .aresetn,
        .s_axis_tdata,
        .s_axis_tvalid,
        .s_axis_tready,
        .s_axis_tuser,
        .s_axis_tlast,
        .m_axis_tdata,
        .m_axis_tvalid,
        .m_axis_tready,
        .m_axis_tuser,
        .m_axis_tlast,
        .cfg_mode,
        .cfg_threshold,
        .cfg_frame_width,
        .cfg_frame_height,
        .status_in_frame,
        .status_protocol_error
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

    function automatic logic [23:0] source_pixel(
        input integer pattern_index,
        input integer pixel_index
    );
        logic [7:0] value;
        integer column_index;
        begin
            value = pixel_index[7:0];
            column_index = pixel_index % FRAME_WIDTH;

            case (pattern_index)
                0: source_pixel = {
                    value + 8'd3,
                    value + 8'd41,
                    value + 8'd97
                };
                1: begin
                    value = value + 8'd20;
                    source_pixel = {value, value, value};
                end
                2, 3: begin
                    value = (column_index == (FRAME_WIDTH - 1)) ? 8'hff : 8'h00;
                    source_pixel = {value, value, value};
                end
                4: source_pixel = {
                    value + 8'd11,
                    value + 8'd33,
                    value + 8'd55
                };
                default: source_pixel = {
                    value + 8'd101,
                    value + 8'd67,
                    value + 8'd29
                };
            endcase
        end
    endfunction

    function automatic logic [23:0] expected_pixel(
        input integer pattern_index,
        input logic [1:0] mode,
        input integer pixel_index
    );
        logic [23:0] source_value;
        begin
            source_value = source_pixel(pattern_index, pixel_index);

            case (mode)
                MODE_PASSTHROUGH: expected_pixel = source_value;
                MODE_GRAYSCALE: expected_pixel = source_value;
                MODE_SOBEL_MAGNITUDE,
                MODE_BINARY_EDGE: begin
                    expected_pixel =
                        (pixel_index == 4)
                        ? 24'hffffff
                        : 24'h000000;
                end
                default: expected_pixel = source_value;
            endcase
        end
    endfunction

    task automatic enqueue_expected_frame(
        input integer pattern_index,
        input logic [1:0] mode
    );
        expected_token_t expected;
        integer pixel_index;
        begin
            for (pixel_index = 0; pixel_index < FRAME_PIXELS; pixel_index = pixel_index + 1) begin
                expected.data = expected_pixel(pattern_index, mode, pixel_index);
                expected.user_marker = pixel_index == 0;
                expected.last_marker = (pixel_index % FRAME_WIDTH) == (FRAME_WIDTH - 1);
                expected_tokens.push_back(expected);
            end
        end
    endtask

    task automatic step(
        input logic source_valid,
        input logic [23:0] source_data,
        input logic source_user,
        input logic source_last,
        input logic sink_ready,
        output logic input_accepted
    );
        logic output_accepted;
        expected_token_t expected;
        begin
            @(negedge aclk);
            s_axis_tvalid = source_valid;
            s_axis_tdata = source_data;
            s_axis_tuser = source_user;
            s_axis_tlast = source_last;
            m_axis_tready = sink_ready;
            #1;

            input_accepted = source_valid && s_axis_tready;
            output_accepted = m_axis_tvalid && sink_ready;

            if (output_was_stalled) begin
                check(m_axis_tvalid, "output valid dropped while stalled");
                check(m_axis_tdata === held_output_data, "output data changed while stalled");
                check(m_axis_tuser === held_output_user, "output SOF changed while stalled");
                check(m_axis_tlast === held_output_last, "output EOL changed while stalled");
            end

            if (m_axis_tvalid && !sink_ready) begin
                if (!output_was_stalled) begin
                    held_output_data = m_axis_tdata;
                    held_output_user = m_axis_tuser;
                    held_output_last = m_axis_tlast;
                end
                output_was_stalled = 1'b1;
            end else begin
                output_was_stalled = 1'b0;
            end

            if (output_accepted) begin
                check(expected_tokens.size() != 0, "core emitted an unexpected output token");
                expected = expected_tokens.pop_front();
                check(m_axis_tdata === expected.data, "core output pixel mismatch");
                check(m_axis_tuser === expected.user_marker, "core output SOF mismatch");
                check(m_axis_tlast === expected.last_marker, "core output EOL mismatch");
                output_count = output_count + 1;
            end

            if (input_accepted) begin
                input_count = input_count + 1;
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
            s_axis_tdata = 24'd0;
            s_axis_tvalid = 1'b0;
            s_axis_tuser = 1'b0;
            s_axis_tlast = 1'b0;
            m_axis_tready = 1'b0;
            cfg_mode = MODE_PASSTHROUGH;
            cfg_threshold = 8'd0;
            cfg_frame_width = FRAME_WIDTH_VALUE;
            cfg_frame_height = FRAME_HEIGHT_VALUE;
            expected_tokens.delete();
            output_was_stalled = 1'b0;
            cycle_index = 0;
            input_count = 0;
            output_count = 0;

            repeat (3) @(posedge aclk);
            #1;
            check(!m_axis_tvalid, "output valid remained asserted after reset");
            check(!status_in_frame, "frame status remained asserted after reset");
            check(!status_protocol_error, "protocol status remained asserted after reset");

            @(negedge aclk);
            aresetn = 1'b1;
            #1;
        end
    endtask

    task automatic send_pixel(
        input logic [23:0] pixel_data,
        input logic user_marker,
        input logic last_marker,
        input logic insert_source_bubble
    );
        logic accepted;
        logic _unused_accepted;
        logic sink_ready;
        begin
            if (insert_source_bubble) begin
                sink_ready = ((cycle_index % 4) != 0);
                step(1'b0, 24'd0, 1'b0, 1'b0, sink_ready, _unused_accepted);
            end

            accepted = 1'b0;
            while (!accepted) begin
                sink_ready =
                    ((cycle_index % 5) != 0)
                    && ((cycle_index % 11) != 0);
                step(
                    1'b1,
                    pixel_data,
                    user_marker,
                    last_marker,
                    sink_ready,
                    accepted
                );
            end
        end
    endtask

    task automatic send_complete_frame(
        input integer pattern_index,
        input logic [1:0] mode,
        input logic [7:0] threshold,
        input logic change_configuration_midframe
    );
        integer pixel_index;
        begin
            cfg_mode = mode;
            cfg_threshold = threshold;
            cfg_frame_width = FRAME_WIDTH_VALUE;
            cfg_frame_height = FRAME_HEIGHT_VALUE;
            enqueue_expected_frame(pattern_index, mode);

            for (pixel_index = 0; pixel_index < FRAME_PIXELS; pixel_index = pixel_index + 1) begin
                send_pixel(
                    source_pixel(pattern_index, pixel_index),
                    pixel_index == 0,
                    (pixel_index % FRAME_WIDTH) == (FRAME_WIDTH - 1),
                    (pixel_index % 4) == 2
                );

                if (change_configuration_midframe && (pixel_index == 0)) begin
                    cfg_mode = MODE_GRAYSCALE;
                    cfg_threshold = 8'hff;
                    cfg_frame_width = MAX_WIDTH_VALUE;
                    cfg_frame_height = MAX_HEIGHT_VALUE;
                end
            end
        end
    endtask

    task automatic send_continuous_passthrough_frame;
        logic accepted;
        integer pixel_index;
        begin
            cfg_mode = MODE_PASSTHROUGH;
            cfg_threshold = 8'd0;
            cfg_frame_width = FRAME_WIDTH_VALUE;
            cfg_frame_height = FRAME_HEIGHT_VALUE;
            enqueue_expected_frame(0, MODE_PASSTHROUGH);

            for (pixel_index = 0; pixel_index < FRAME_PIXELS; pixel_index = pixel_index + 1) begin
                step(
                    1'b1,
                    source_pixel(0, pixel_index),
                    pixel_index == 0,
                    (pixel_index % FRAME_WIDTH) == (FRAME_WIDTH - 1),
                    1'b1,
                    accepted
                );
                check(accepted, "continuous legal frame encountered an input bubble");
            end
        end
    endtask

    task automatic check_drain_serialization;
        begin
            @(negedge aclk);
            s_axis_tvalid = 1'b0;
            s_axis_tuser = 1'b0;
            s_axis_tlast = 1'b0;
            m_axis_tready = 1'b0;
            #1;
            check(status_in_frame, "frame status dropped before output EOF");
            check(!s_axis_tready, "next frame was not blocked during drain");
            @(posedge aclk);
            #1;
        end
    endtask

    task automatic drain_expected_frame;
        integer guard;
        logic _unused_accepted;
        logic sink_ready;
        begin
            guard = 0;
            while (expected_tokens.size() != 0) begin
                sink_ready =
                    ((cycle_index % 4) != 0)
                    && ((cycle_index % 9) != 0);
                step(1'b0, 24'd0, 1'b0, 1'b0, sink_ready, _unused_accepted);
                guard = guard + 1;
                check(guard < 256, "core did not drain the expected frame");
            end

            step(1'b0, 24'd0, 1'b0, 1'b0, 1'b1, _unused_accepted);
            check(!m_axis_tvalid, "core emitted an extra token after frame drain");
            check(!status_in_frame, "frame status did not clear at output EOF");
        end
    endtask

    integer pixel_index;
    expected_token_t single_expected;

    initial begin
        aresetn = 1'b0;
        s_axis_tdata = 24'd0;
        s_axis_tvalid = 1'b0;
        s_axis_tuser = 1'b0;
        s_axis_tlast = 1'b0;
        m_axis_tready = 1'b0;
        cfg_mode = MODE_PASSTHROUGH;
        cfg_threshold = 8'd0;
        cfg_frame_width = FRAME_WIDTH_VALUE;
        cfg_frame_height = FRAME_HEIGHT_VALUE;
        output_was_stalled = 1'b0;
        cycle_index = 0;
        input_count = 0;
        output_count = 0;

        reset_dut();

        // A legal 1x1 frame must keep status_in_frame observable through its
        // delayed output, even though ingress finishes on the accepted SOF.
        cfg_mode = MODE_PASSTHROUGH;
        cfg_threshold = 8'd0;
        cfg_frame_width = 16'd1;
        cfg_frame_height = 16'd1;
        single_expected.data = 24'h123456;
        single_expected.user_marker = 1'b1;
        single_expected.last_marker = 1'b1;
        expected_tokens.push_back(single_expected);
        send_pixel(24'h123456, 1'b1, 1'b1, 1'b0);
        check(status_in_frame, "1x1 frame status was not observable after input");
        check_drain_serialization();
        drain_expected_frame();
        check(!status_protocol_error, "legal 1x1 frame raised protocol error");

        // Raw configuration changes after the accepted SOF must not affect the
        // active passthrough frame.
        send_complete_frame(0, MODE_PASSTHROUGH, 8'd0, 1'b1);
        check_drain_serialization();
        drain_expected_frame();
        check(!status_protocol_error, "legal passthrough frame raised protocol error");

        send_complete_frame(1, MODE_GRAYSCALE, 8'd0, 1'b0);
        check_drain_serialization();
        drain_expected_frame();

        send_complete_frame(2, MODE_SOBEL_MAGNITUDE, 8'd0, 1'b0);
        check_drain_serialization();
        drain_expected_frame();

        // The 3x3 vertical step has center magnitude 1020. Threshold 169 gives
        // 1014, so strict comparison produces one white center pixel.
        send_complete_frame(3, MODE_BINARY_EDGE, 8'd169, 1'b0);
        check_drain_serialization();
        drain_expected_frame();
        check(!status_protocol_error, "legal four-mode run raised protocol error");

        send_continuous_passthrough_frame();
        check_drain_serialization();
        drain_expected_frame();
        check(!status_protocol_error, "continuous legal frame raised protocol error");

        // Interrupt a 4x4 frame before its first window result, then hold a new
        // legal SOF through recovery. No partial payload may contaminate it.
        cfg_mode = MODE_PASSTHROUGH;
        cfg_threshold = 8'd0;
        cfg_frame_width = MAX_WIDTH_VALUE;
        cfg_frame_height = MAX_HEIGHT_VALUE;
        for (pixel_index = 0; pixel_index < 3; pixel_index = pixel_index + 1) begin
            send_pixel(
                source_pixel(4, pixel_index),
                pixel_index == 0,
                1'b0,
                1'b0
            );
        end
        check(status_in_frame, "interrupted frame did not enter active status");

        send_complete_frame(5, MODE_PASSTHROUGH, 8'd0, 1'b0);
        check_drain_serialization();
        drain_expected_frame();
        check(status_protocol_error, "unexpected mid-frame SOF was not reported");

        check(input_count == (6 * FRAME_PIXELS) + 4,
              "accepted input transaction count mismatch");
        check(output_count == (6 * FRAME_PIXELS) + 1,
              "output transaction count mismatch");

        $display("video_stream_core_tb: PASS");
        $finish;
    end

endmodule
