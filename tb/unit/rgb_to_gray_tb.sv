`timescale 1ns/1ps

module rgb_to_gray_tb;

    import video_pkg::video_payload_t;

    logic aclk;
    logic aresetn;

    video_payload_t s_axis_payload;
    logic s_axis_tvalid;
    logic s_axis_tready;

    video_payload_t m_axis_payload;
    logic m_axis_tvalid;
    logic m_axis_tready;

    video_payload_t expected_queue[$];
    video_payload_t held_output;
    logic output_was_stalled;
    integer cycle_index;
    integer accepted_count;
    integer output_count;

    initial begin
        aclk = 1'b0;
        forever #5 aclk = ~aclk;
    end

    rgb_to_gray dut (
        .aclk,
        .aresetn,
        .s_axis_payload,
        .s_axis_tvalid,
        .s_axis_tready,
        .m_axis_payload,
        .m_axis_tvalid,
        .m_axis_tready
    );

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

    function automatic video_payload_t reference_conversion(
        input video_payload_t payload
    );
        video_payload_t converted;
        logic [15:0] weighted_sum;
        logic [7:0] _unused_fraction;
        begin
            converted = payload;
            weighted_sum =
                (16'd77 * {8'd0, payload.rgb[23:16]})
                + (16'd150 * {8'd0, payload.rgb[15:8]})
                + (16'd29 * {8'd0, payload.rgb[7:0]})
                + 16'd128;
            {converted.gray, _unused_fraction} = weighted_sum;
            return converted;
        end
    endfunction

    task automatic step(
        input logic source_valid,
        input video_payload_t source_payload,
        input logic sink_ready,
        output logic source_accepted
    );
        logic output_accepted;
        video_payload_t expected_output;
        begin
            @(negedge aclk);
            s_axis_tvalid = source_valid;
            s_axis_payload = source_payload;
            m_axis_tready = sink_ready;
            #1;

            source_accepted = source_valid && s_axis_tready;
            output_accepted = m_axis_tvalid && sink_ready;

            if (output_was_stalled) begin
                check(m_axis_tvalid, "output valid dropped while stalled");
                check(
                    m_axis_payload === held_output,
                    "output payload changed while stalled"
                );
            end

            if (m_axis_tvalid && !sink_ready) begin
                if (!output_was_stalled) begin
                    held_output = m_axis_payload;
                end
                output_was_stalled = 1'b1;
            end else begin
                output_was_stalled = 1'b0;
            end

            if (output_accepted) begin
                check(
                    expected_queue.size() != 0,
                    "unexpected output transfer"
                );
                expected_output = expected_queue.pop_front();
                check(
                    m_axis_payload === expected_output,
                    "grayscale result, metadata, or ordering mismatch"
                );
                output_count = output_count + 1;
            end

            if (source_accepted) begin
                expected_queue.push_back(
                    reference_conversion(source_payload)
                );
                accepted_count = accepted_count + 1;
            end

            @(posedge aclk);
            #1;
            cycle_index = cycle_index + 1;
            check(
                expected_queue.size() <= 2,
                "pipeline accepted more than two buffered tokens"
            );
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge aclk);
            aresetn = 1'b0;
            s_axis_payload = '0;
            s_axis_tvalid = 1'b0;
            m_axis_tready = 1'b0;
            expected_queue.delete();
            output_was_stalled = 1'b0;
            cycle_index = 0;
            accepted_count = 0;
            output_count = 0;

            repeat (2) @(posedge aclk);
            #1;
            check(!m_axis_tvalid, "output valid remained asserted after reset");
            check(s_axis_tready, "empty pipeline was not ready after reset");

            @(negedge aclk);
            aresetn = 1'b1;
            #1;
            check(s_axis_tready, "input was not ready after reset release");
        end
    endtask

    task automatic drain_pipeline;
        video_payload_t idle_payload;
        logic _unused_accepted;
        integer guard;
        begin
            idle_payload = '0;
            guard = 0;
            while (expected_queue.size() != 0) begin
                step(1'b0, idle_payload, 1'b1, _unused_accepted);
                guard = guard + 1;
                check(guard < 8, "pipeline did not drain");
            end
            check(!m_axis_tvalid, "output valid remained set after drain");
        end
    endtask

    video_payload_t payload;
    video_payload_t idle_payload;
    logic accepted;
    logic sink_ready;
    logic [31:0] lfsr;
    integer index;

    initial begin
        aresetn = 1'b0;
        s_axis_payload = '0;
        s_axis_tvalid = 1'b0;
        m_axis_tready = 1'b0;
        output_was_stalled = 1'b0;
        cycle_index = 0;
        accepted_count = 0;
        output_count = 0;
        idle_payload = '0;

        check($bits(video_payload_t) == 36, "video_payload_t width changed");

        // Known RGB values, primary colors, and a rounding boundary. With a
        // ready sink every input must be accepted on consecutive clocks.
        reset_dut();
        payload = make_payload(24'h000000, 8'ha5, 1'b1, 1'b0, 1'b0, 1'b1);
        step(1'b1, payload, 1'b1, accepted);
        check(accepted, "black pixel was not accepted");

        payload = make_payload(24'hffffff, 8'h5a, 1'b0, 1'b0, 1'b0, 1'b0);
        step(1'b1, payload, 1'b1, accepted);
        check(accepted, "white pixel was not accepted");

        payload = make_payload(24'hff0000, 8'hff, 1'b0, 1'b0, 1'b0, 1'b0);
        step(1'b1, payload, 1'b1, accepted);
        check(accepted, "red pixel was not accepted");

        payload = make_payload(24'h00ff00, 8'hff, 1'b0, 1'b1, 1'b0, 1'b0);
        step(1'b1, payload, 1'b1, accepted);
        check(accepted, "green pixel was not accepted");

        payload = make_payload(24'h0000ff, 8'hff, 1'b0, 1'b0, 1'b0, 1'b0);
        step(1'b1, payload, 1'b1, accepted);
        check(accepted, "blue pixel was not accepted");

        payload = make_payload(24'h000004, 8'hee, 1'b0, 1'b0, 1'b0, 1'b0);
        step(1'b1, payload, 1'b1, accepted);
        check(accepted, "lower rounding-boundary pixel was not accepted");

        payload = make_payload(24'h000005, 8'hee, 1'b0, 1'b1, 1'b1, 1'b1);
        step(1'b1, payload, 1'b1, accepted);
        check(accepted, "upper rounding-boundary pixel was not accepted");

        drain_pipeline();
        check(accepted_count == 7, "known-vector input count mismatch");
        check(output_count == 7, "known-vector output count mismatch");

        // Fill both pipeline stages and hold the downstream stalled. The
        // oldest result and every metadata bit must remain stable.
        reset_dut();
        payload = make_payload(24'h123456, 8'h11, 1'b1, 1'b0, 1'b0, 1'b1);
        step(1'b1, payload, 1'b0, accepted);
        check(accepted, "first stalled token was not accepted");

        payload = make_payload(24'habcdef, 8'h22, 1'b0, 1'b1, 1'b1, 1'b0);
        step(1'b1, payload, 1'b0, accepted);
        check(accepted, "second stalled token was not accepted");
        check(!s_axis_tready, "full pipeline did not apply backpressure");

        repeat (8) begin
            step(1'b0, idle_payload, 1'b0, accepted);
        end
        check(expected_queue.size() == 2, "stalled tokens were lost");
        drain_pipeline();

        // Reset while full must discard both valid stages.
        payload = make_payload(24'h102030, 8'h33, 1'b0, 1'b0, 1'b0, 1'b0);
        step(1'b1, payload, 1'b0, accepted);
        payload = make_payload(24'h405060, 8'h44, 1'b0, 1'b0, 1'b0, 1'b0);
        step(1'b1, payload, 1'b0, accepted);
        check(expected_queue.size() == 2, "reset test did not fill pipeline");
        reset_dut();
        check(expected_queue.size() == 0, "reset did not clear scoreboard");

        // Deterministic pseudo-random RGB and metadata with source bubbles and
        // downstream backpressure. A stalled source holds the same payload.
        lfsr = 32'h1ace_beef;
        for (index = 0; index < 64; index = index + 1) begin
            lfsr = {
                lfsr[30:0],
                lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]
            };
            payload = make_payload(
                lfsr[23:0],
                lfsr[31:24],
                lfsr[0],
                lfsr[1],
                lfsr[2],
                lfsr[3]
            );

            if ((index % 7) == 0) begin
                sink_ready = ((cycle_index % 5) != 0);
                step(1'b0, idle_payload, sink_ready, accepted);
            end

            accepted = 1'b0;
            while (!accepted) begin
                sink_ready =
                    ((cycle_index % 5) != 0)
                    && ((cycle_index % 11) != 0);
                step(1'b1, payload, sink_ready, accepted);
            end
        end

        drain_pipeline();
        check(accepted_count == 64, "random input count mismatch");
        check(output_count == 64, "random output count mismatch");

        $display("rgb_to_gray_tb: PASS");
        $finish;
    end

endmodule
