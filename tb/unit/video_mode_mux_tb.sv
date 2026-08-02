`timescale 1ns/1ps

module video_mode_mux_tb;

    import video_pkg::video_payload_t;

    localparam logic [1:0] MODE_PASSTHROUGH = 2'd0;
    localparam logic [1:0] MODE_GRAYSCALE = 2'd1;
    localparam logic [1:0] MODE_SOBEL_MAGNITUDE = 2'd2;
    localparam logic [1:0] MODE_BINARY_EDGE = 2'd3;

    logic aclk;
    logic aresetn;

    video_payload_t s_aligned_payload;
    logic s_aligned_valid;
    logic s_aligned_ready;

    logic [7:0] s_sobel_magnitude;
    logic [7:0] s_sobel_edge;
    logic s_sobel_valid;
    logic s_sobel_ready;

    logic [1:0] active_mode;

    video_payload_t m_axis_payload;
    logic m_axis_tvalid;
    logic m_axis_tready;

    video_mode_mux dut (
        .aclk,
        .aresetn,
        .s_aligned_payload,
        .s_aligned_valid,
        .s_aligned_ready,
        .s_sobel_magnitude,
        .s_sobel_edge,
        .s_sobel_valid,
        .s_sobel_ready,
        .active_mode,
        .m_axis_payload,
        .m_axis_tvalid,
        .m_axis_tready
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

    function automatic video_payload_t make_payload(
        input logic [23:0] rgb,
        input logic [7:0] gray,
        input logic sof,
        input logic eol,
        input logic eof,
        input logic border
    );
        video_payload_t payload;
        begin
            payload.rgb = rgb;
            payload.gray = gray;
            payload.sof = sof;
            payload.eol = eol;
            payload.eof = eof;
            payload.border = border;
            return payload;
        end
    endfunction

    task automatic reset_dut;
        begin
            @(negedge aclk);
            aresetn = 1'b0;
            s_aligned_payload = '0;
            s_aligned_valid = 1'b0;
            s_sobel_magnitude = 8'd0;
            s_sobel_edge = 8'd0;
            s_sobel_valid = 1'b0;
            active_mode = MODE_PASSTHROUGH;
            m_axis_tready = 1'b0;

            repeat (2) @(posedge aclk);
            #1;
            check(!m_axis_tvalid, "output valid remained asserted after reset");

            @(negedge aclk);
            aresetn = 1'b1;
            #1;
        end
    endtask

    task automatic present_pair(
        input video_payload_t payload,
        input logic [7:0] magnitude,
        input logic [7:0] edge_value
    );
        begin
            @(negedge aclk);
            s_aligned_payload = payload;
            s_aligned_valid = 1'b1;
            s_sobel_magnitude = magnitude;
            s_sobel_edge = edge_value;
            s_sobel_valid = 1'b1;
            #1;
            check(s_aligned_ready, "aligned branch was not ready for a complete pair");
            check(s_sobel_ready, "Sobel branch was not ready for a complete pair");

            @(posedge aclk);
            #1;

            @(negedge aclk);
            s_aligned_valid = 1'b0;
            s_sobel_valid = 1'b0;
            #1;
        end
    endtask

    task automatic expect_output(
        input video_payload_t source_payload,
        input logic [23:0] expected_rgb,
        input string test_name
    );
        video_payload_t expected_payload;
        begin
            expected_payload = source_payload;
            expected_payload.rgb = expected_rgb;
            check(m_axis_tvalid, {test_name, ": output valid missing"});
            check(
                m_axis_payload === expected_payload,
                {test_name, ": RGB or payload metadata mismatch"}
            );
        end
    endtask

    task automatic consume_output;
        begin
            m_axis_tready = 1'b1;
            @(posedge aclk);
            #1;
            @(negedge aclk);
            m_axis_tready = 1'b0;
            #1;
        end
    endtask

    video_payload_t payload;
    video_payload_t held_payload;

    initial begin
        aresetn = 1'b0;
        s_aligned_payload = '0;
        s_aligned_valid = 1'b0;
        s_sobel_magnitude = 8'd0;
        s_sobel_edge = 8'd0;
        s_sobel_valid = 1'b0;
        active_mode = MODE_PASSTHROUGH;
        m_axis_tready = 1'b0;

        reset_dut();

        // Each mode selects its specified RGB888 source.
        payload = make_payload(24'h123456, 8'h7a, 1'b1, 1'b0, 1'b0, 1'b0);
        active_mode = MODE_PASSTHROUGH;
        present_pair(payload, 8'h9b, 8'hff);
        expect_output(payload, 24'h123456, "passthrough mode");
        consume_output();

        payload = make_payload(24'habcdef, 8'h35, 1'b1, 1'b0, 1'b0, 1'b0);
        active_mode = MODE_GRAYSCALE;
        present_pair(payload, 8'h92, 8'h00);
        expect_output(payload, 24'h353535, "grayscale mode");
        consume_output();

        payload = make_payload(24'h010203, 8'h44, 1'b1, 1'b0, 1'b0, 1'b0);
        active_mode = MODE_SOBEL_MAGNITUDE;
        present_pair(payload, 8'hc7, 8'h00);
        expect_output(payload, 24'hc7c7c7, "Sobel magnitude mode");
        consume_output();

        payload = make_payload(24'h556677, 8'h88, 1'b1, 1'b0, 1'b0, 1'b0);
        active_mode = MODE_BINARY_EDGE;
        present_pair(payload, 8'h73, 8'hff);
        expect_output(payload, 24'hffffff, "binary edge mode");
        consume_output();

        // Border override applies only to Sobel modes.
        payload = make_payload(24'h89abcd, 8'h5e, 1'b1, 1'b1, 1'b1, 1'b1);
        active_mode = MODE_SOBEL_MAGNITUDE;
        present_pair(payload, 8'hff, 8'hff);
        expect_output(payload, 24'h000000, "magnitude border");
        consume_output();

        payload = make_payload(24'h89abcd, 8'h5e, 1'b1, 1'b1, 1'b1, 1'b1);
        active_mode = MODE_GRAYSCALE;
        present_pair(payload, 8'hff, 8'hff);
        expect_output(payload, 24'h5e5e5e, "grayscale border");
        consume_output();

        // A branch cannot be consumed before its matching token arrives.
        @(negedge aclk);
        payload = make_payload(24'h2468ac, 8'h3c, 1'b1, 1'b0, 1'b0, 1'b0);
        active_mode = MODE_PASSTHROUGH;
        s_aligned_payload = payload;
        s_aligned_valid = 1'b1;
        s_sobel_valid = 1'b0;
        #1;
        check(!s_aligned_ready, "aligned token was accepted without Sobel data");
        check(s_sobel_ready, "missing Sobel branch was not invited to complete the join");

        @(posedge aclk);
        #1;
        check(!m_axis_tvalid, "unpaired aligned token reached the output");

        @(negedge aclk);
        s_sobel_magnitude = 8'h11;
        s_sobel_edge = 8'h00;
        s_sobel_valid = 1'b1;
        #1;
        check(s_aligned_ready && s_sobel_ready, "completed pair was not accepted");

        @(posedge aclk);
        #1;
        @(negedge aclk);
        s_aligned_valid = 1'b0;
        s_sobel_valid = 1'b0;
        #1;
        expect_output(payload, 24'h2468ac, "delayed Sobel join");
        consume_output();

        @(negedge aclk);
        payload = make_payload(24'h13579b, 8'h2d, 1'b1, 1'b0, 1'b0, 1'b0);
        s_aligned_valid = 1'b0;
        s_sobel_magnitude = 8'h6a;
        s_sobel_edge = 8'hff;
        s_sobel_valid = 1'b1;
        #1;
        check(s_aligned_ready, "missing aligned branch was not invited to complete the join");
        check(!s_sobel_ready, "Sobel token was accepted without aligned payload");

        @(posedge aclk);
        #1;
        check(!m_axis_tvalid, "unpaired Sobel token reached the output");

        @(negedge aclk);
        active_mode = MODE_SOBEL_MAGNITUDE;
        s_aligned_payload = payload;
        s_aligned_valid = 1'b1;
        #1;
        check(s_aligned_ready && s_sobel_ready, "reverse-order pair was not accepted");

        @(posedge aclk);
        #1;
        @(negedge aclk);
        s_aligned_valid = 1'b0;
        s_sobel_valid = 1'b0;
        #1;
        expect_output(payload, 24'h6a6a6a, "delayed aligned join");
        consume_output();

        // Mid-frame active-mode changes do not affect the captured frame mode.
        payload = make_payload(24'h102030, 8'h46, 1'b1, 1'b0, 1'b0, 1'b0);
        active_mode = MODE_GRAYSCALE;
        present_pair(payload, 8'h8f, 8'hff);
        expect_output(payload, 24'h464646, "frame mode at SOF");
        consume_output();

        active_mode = MODE_BINARY_EDGE;
        payload = make_payload(24'h405060, 8'h28, 1'b0, 1'b1, 1'b1, 1'b0);
        present_pair(payload, 8'h7c, 8'hff);
        expect_output(payload, 24'h282828, "mid-frame mode change");
        consume_output();

        // The next SOF atomically selects the new active mode.
        payload = make_payload(24'h708090, 8'h19, 1'b1, 1'b1, 1'b1, 1'b0);
        present_pair(payload, 8'h55, 8'hff);
        expect_output(payload, 24'hffffff, "next-frame mode update");

        // Registered output and both branch ready signals remain stable on stall.
        held_payload = m_axis_payload;
        active_mode = MODE_PASSTHROUGH;
        @(negedge aclk);
        s_aligned_payload = make_payload(24'hfedcba, 8'h99, 1'b1, 1'b1, 1'b1, 1'b0);
        s_aligned_valid = 1'b1;
        s_sobel_magnitude = 8'haa;
        s_sobel_edge = 8'h00;
        s_sobel_valid = 1'b1;
        m_axis_tready = 1'b0;
        #1;
        check(!s_aligned_ready && !s_sobel_ready, "full output slot accepted another pair");

        repeat (3) begin
            @(posedge aclk);
            #1;
            check(m_axis_tvalid, "output valid dropped while stalled");
            check(m_axis_payload === held_payload, "output payload changed while stalled");
        end

        // Pop and replace in one cycle to preserve one-token throughput.
        @(negedge aclk);
        m_axis_tready = 1'b1;
        #1;
        check(s_aligned_ready && s_sobel_ready, "simultaneous output pop/input join was blocked");
        @(posedge aclk);
        #1;
        @(negedge aclk);
        s_aligned_valid = 1'b0;
        s_sobel_valid = 1'b0;
        m_axis_tready = 1'b0;
        #1;
        expect_output(s_aligned_payload, 24'hfedcba, "simultaneous replacement");
        consume_output();

        // Reset discards an unconsumed registered result.
        payload = make_payload(24'h010101, 8'h01, 1'b1, 1'b1, 1'b1, 1'b0);
        active_mode = MODE_PASSTHROUGH;
        present_pair(payload, 8'h01, 8'h00);
        check(m_axis_tvalid, "pre-reset output token missing");
        reset_dut();
        check(!m_axis_tvalid, "stale output escaped reset");

        $display("video_mode_mux_tb: PASS");
        $finish;
    end

endmodule
