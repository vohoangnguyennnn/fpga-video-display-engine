`timescale 1ns/1ps

module frame_coord_tracker_tb;

    import video_pkg::video_payload_t;

    localparam integer MAX_WIDTH  = 8;
    localparam integer MAX_HEIGHT = 6;

    logic           aclk;
    logic           aresetn;
    logic [23:0]    s_axis_tdata;
    logic           s_axis_tvalid;
    logic           s_axis_tready;
    logic           s_axis_tuser;
    logic           s_axis_tlast;
    logic [15:0]    cfg_frame_width;
    logic [15:0]    cfg_frame_height;
    video_payload_t m_axis_payload;
    logic           m_axis_tvalid;
    logic           m_axis_tready;
    logic [15:0]    active_width;
    logic [15:0]    active_height;
    logic           tracker_in_frame;
    logic           status_protocol_error;

    frame_coord_tracker #(
        .MAX_WIDTH  (MAX_WIDTH),
        .MAX_HEIGHT (MAX_HEIGHT)
    ) dut (
        .aclk,
        .aresetn,
        .s_axis_tdata,
        .s_axis_tvalid,
        .s_axis_tready,
        .s_axis_tuser,
        .s_axis_tlast,
        .cfg_frame_width,
        .cfg_frame_height,
        .m_axis_payload,
        .m_axis_tvalid,
        .m_axis_tready,
        .active_width,
        .active_height,
        .tracker_in_frame,
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

    task automatic reset_dut;
        begin
            @(negedge aclk);
            aresetn          = 1'b0;
            s_axis_tvalid    = 1'b0;
            s_axis_tdata     = 24'd0;
            s_axis_tuser     = 1'b0;
            s_axis_tlast     = 1'b0;
            m_axis_tready    = 1'b0;
            cfg_frame_width  = 16'd0;
            cfg_frame_height = 16'd0;

            repeat (2) @(posedge aclk);
            #1;
            check(!m_axis_tvalid, "valid output remained asserted after reset");
            check(!tracker_in_frame, "tracker remained active after reset");
            check(!status_protocol_error, "protocol error remained set after reset");
            check(active_width == 16'd0, "active width did not clear on reset");
            check(active_height == 16'd0, "active height did not clear on reset");

            @(negedge aclk);
            aresetn = 1'b1;
            #1;
        end
    endtask

    task automatic send_beat(
        input logic [23:0] rgb,
        input logic        sof,
        input logic        eol,
        input logic        sink_ready,
        input logic        expected_input_ready,
        input logic        expected_output_valid,
        input logic        expected_eof,
        input logic        expected_border
    );
        begin
            @(negedge aclk);
            s_axis_tdata  = rgb;
            s_axis_tuser  = sof;
            s_axis_tlast  = eol;
            s_axis_tvalid = 1'b1;
            m_axis_tready = sink_ready;
            #1;

            check(
                s_axis_tready == expected_input_ready,
                "input ready mismatch"
            );
            check(
                m_axis_tvalid == expected_output_valid,
                "output valid mismatch"
            );

            if (expected_output_valid) begin
                check(m_axis_payload.rgb == rgb, "RGB metadata mismatch");
                check(m_axis_payload.gray == 8'd0, "gray field was not initialized");
                check(m_axis_payload.sof == sof, "SOF metadata mismatch");
                check(m_axis_payload.eol == eol, "EOL metadata mismatch");
                check(m_axis_payload.eof == expected_eof, "EOF metadata mismatch");
                check(m_axis_payload.border == expected_border, "border metadata mismatch");
            end

            @(posedge aclk);
            #1;
        end
    endtask

    integer x;
    integer y;
    logic   expected_border;

    initial begin
        aresetn          = 1'b0;
        s_axis_tdata     = 24'd0;
        s_axis_tvalid    = 1'b0;
        s_axis_tuser     = 1'b0;
        s_axis_tlast     = 1'b0;
        cfg_frame_width  = 16'd0;
        cfg_frame_height = 16'd0;
        m_axis_tready    = 1'b0;

        check($bits(video_payload_t) == 36, "video_payload_t width changed");

        // No input or output transfer is permitted while reset is active.
        @(negedge aclk);
        cfg_frame_width  = 16'd3;
        cfg_frame_height = 16'd3;
        s_axis_tdata     = 24'h012345;
        s_axis_tvalid    = 1'b1;
        s_axis_tuser     = 1'b1;
        s_axis_tlast     = 1'b0;
        m_axis_tready    = 1'b1;
        #1;
        check(!s_axis_tready, "input ready asserted during reset");
        check(!m_axis_tvalid, "output valid asserted during reset");
        @(posedge aclk);
        #1;

        // Legal raster, configuration commit, and internal metadata.
        reset_dut();
        cfg_frame_width  = 16'd3;
        cfg_frame_height = 16'd3;
        for (y = 0; y < 3; y = y + 1) begin
            for (x = 0; x < 3; x = x + 1) begin
                expected_border = (x == 0) || (x == 2)
                    || (y == 0) || (y == 2);
                send_beat(
                    24'h100000 | {20'd0, y[1:0], x[1:0]},
                    (x == 0) && (y == 0),
                    x == 2,
                    1'b1,
                    1'b1,
                    1'b1,
                    (x == 2) && (y == 2),
                    expected_border
                );

                if ((x == 0) && (y == 0)) begin
                    check(active_width == 16'd3, "width was not committed at SOF");
                    check(active_height == 16'd3, "height was not committed at SOF");
                    cfg_frame_width  = 16'd1;
                    cfg_frame_height = 16'd1;
                end

                check(
                    tracker_in_frame == !((x == 2) && (y == 2)),
                    "frame-active state changed at the wrong coordinate"
                );
                check(!status_protocol_error, "legal 3x3 frame raised an error");
            end
        end

        check(active_width == 16'd3, "mid-frame width change affected active frame");
        check(active_height == 16'd3, "mid-frame height change affected active frame");

        // The only 1x1 pixel is SOF, EOL, EOF, and border.
        send_beat(
            24'habcdef,
            1'b1,
            1'b1,
            1'b1,
            1'b1,
            1'b1,
            1'b1,
            1'b1
        );
        check(active_width == 16'd1, "1x1 width was not committed");
        check(active_height == 16'd1, "1x1 height was not committed");
        check(!tracker_in_frame, "1x1 frame did not finish on its only pixel");
        check(!status_protocol_error, "legal 1x1 frame raised an error");

        // A stalled SOF must not commit transaction-derived state.
        reset_dut();
        cfg_frame_width  = 16'd2;
        cfg_frame_height = 16'd2;
        send_beat(
            24'h010203,
            1'b1,
            1'b0,
            1'b0,
            1'b0,
            1'b1,
            1'b0,
            1'b1
        );
        check(active_width == 16'd0, "stalled SOF committed width");
        check(active_height == 16'd0, "stalled SOF committed height");
        check(!tracker_in_frame, "stalled SOF started a frame");
        check(!status_protocol_error, "stalled SOF raised an error");

        send_beat(
            24'h010203,
            1'b1,
            1'b0,
            1'b1,
            1'b1,
            1'b1,
            1'b0,
            1'b1
        );
        check(active_width == 16'd2, "accepted SOF did not commit width");
        check(active_height == 16'd2, "accepted SOF did not commit height");
        check(tracker_in_frame, "accepted 2x2 SOF did not start a frame");

        // A non-SOF token while hunting is consumed, suppressed, and flagged.
        reset_dut();
        send_beat(
            24'h111111,
            1'b0,
            1'b0,
            1'b0,
            1'b1,
            1'b0,
            1'b0,
            1'b0
        );
        check(status_protocol_error, "missing SOF was not flagged");
        check(!tracker_in_frame, "missing SOF started a frame");

        // An illegal-dimension SOF is consumed and suppressed.
        reset_dut();
        cfg_frame_width  = 16'd0;
        cfg_frame_height = 16'd2;
        send_beat(
            24'h222222,
            1'b1,
            1'b0,
            1'b0,
            1'b1,
            1'b0,
            1'b0,
            1'b0
        );
        check(status_protocol_error, "zero width was not flagged");
        check(!tracker_in_frame, "illegal dimensions started a frame");

        reset_dut();
        cfg_frame_width  = 16'd9;
        cfg_frame_height = 16'd2;
        send_beat(
            24'h333333,
            1'b1,
            1'b0,
            1'b1,
            1'b1,
            1'b0,
            1'b0,
            1'b0
        );
        check(status_protocol_error, "out-of-range width was not flagged");

        // Early and missing EOL are detected using the committed width.
        reset_dut();
        cfg_frame_width  = 16'd3;
        cfg_frame_height = 16'd2;
        send_beat(24'h400000, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1);
        send_beat(24'h400001, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1);
        check(status_protocol_error, "early EOL was not flagged");

        reset_dut();
        cfg_frame_width  = 16'd3;
        cfg_frame_height = 16'd1;
        send_beat(24'h500000, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1);
        send_beat(24'h500001, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1);
        send_beat(24'h500002, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1);
        check(status_protocol_error, "missing EOL was not flagged");
        check(!tracker_in_frame, "configured final pixel did not end the frame");

        // A legal unexpected SOF reports the interruption and re-establishes
        // coordinate (0,0) with the new dimensions.
        reset_dut();
        cfg_frame_width  = 16'd3;
        cfg_frame_height = 16'd2;
        send_beat(24'h600000, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1);
        cfg_frame_width  = 16'd2;
        cfg_frame_height = 16'd1;
        send_beat(24'h700000, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1);
        check(status_protocol_error, "unexpected SOF was not flagged");
        check(active_width == 16'd2, "replacement SOF did not recommit width");
        check(active_height == 16'd1, "replacement SOF did not recommit height");
        send_beat(24'h700001, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1);
        check(!tracker_in_frame, "replacement frame did not finish");
        check(status_protocol_error, "sticky protocol error cleared unexpectedly");

        @(negedge aclk);
        s_axis_tvalid = 1'b0;
        $display("frame_coord_tracker_tb: PASS");
        $finish;
    end

endmodule
