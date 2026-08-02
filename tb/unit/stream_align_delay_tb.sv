`timescale 1ns/1ps

module stream_align_delay_tb;

    import video_pkg::video_payload_t;

    localparam integer MAX_WIDTH = 3;
    localparam integer ALIGNMENT_DEPTH = MAX_WIDTH + 7;

    logic aclk;
    logic aresetn;

    video_payload_t s_axis_payload;
    logic s_axis_tvalid;
    logic s_axis_tready;

    video_payload_t m_axis_payload;
    logic m_axis_tvalid;
    logic m_axis_tready;

    video_payload_t expected_payloads[$];
    video_payload_t held_payload;
    logic output_was_stalled;
    integer cycle_index;
    integer accepted_count;
    integer output_count;

    stream_align_delay #(
        .MAX_WIDTH(MAX_WIDTH),
        .ALIGNMENT_DEPTH(ALIGNMENT_DEPTH)
    ) dut (
        .aclk,
        .aresetn,
        .s_axis_payload,
        .s_axis_tvalid,
        .s_axis_tready,
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
        input logic [7:0] sequence_value,
        input logic sof,
        input logic eol,
        input logic eof,
        input logic border
    );
        video_payload_t payload;
        begin
            payload.rgb = {
                sequence_value,
                sequence_value + 8'd1,
                sequence_value + 8'd2
            };
            payload.gray = sequence_value ^ 8'ha5;
            payload.sof = sof;
            payload.eol = eol;
            payload.eof = eof;
            payload.border = border;
            return payload;
        end
    endfunction

    task automatic step(
        input logic source_valid,
        input video_payload_t source_payload,
        input logic sink_ready,
        output logic input_accepted
    );
        logic output_accepted;
        video_payload_t expected;
        begin
            @(negedge aclk);
            s_axis_tvalid = source_valid;
            s_axis_payload = source_payload;
            m_axis_tready = sink_ready;
            #1;

            input_accepted = source_valid && s_axis_tready;
            output_accepted = m_axis_tvalid && sink_ready;

            if (output_was_stalled) begin
                check(
                    m_axis_tvalid,
                    "alignment output valid dropped while stalled"
                );
                check(
                    m_axis_payload === held_payload,
                    "alignment payload changed while stalled"
                );
            end

            if (m_axis_tvalid && !sink_ready) begin
                if (!output_was_stalled) begin
                    held_payload = m_axis_payload;
                end
                output_was_stalled = 1'b1;
            end else begin
                output_was_stalled = 1'b0;
            end

            if (output_accepted) begin
                check(
                    expected_payloads.size() != 0,
                    "alignment FIFO emitted an unexpected token"
                );
                expected = expected_payloads.pop_front();
                check(
                    m_axis_payload === expected,
                    "payload, metadata, or token ordering mismatch"
                );
                output_count = output_count + 1;
            end

            if (input_accepted) begin
                expected_payloads.push_back(source_payload);
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
            m_axis_tready = 1'b0;
            expected_payloads.delete();
            output_was_stalled = 1'b0;
            cycle_index = 0;
            accepted_count = 0;
            output_count = 0;

            repeat (2) @(posedge aclk);
            #1;
            check(
                !m_axis_tvalid,
                "alignment output valid remained asserted after reset"
            );
            check(s_axis_tready, "alignment input was not ready after reset");

            @(negedge aclk);
            aresetn = 1'b1;
            #1;
        end
    endtask

    task automatic send_payload(
        input video_payload_t payload,
        input logic apply_backpressure
    );
        logic accepted;
        logic sink_ready;
        begin
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
        end
    endtask

    task automatic wait_for_outputs(input integer target_count);
        integer guard;
        logic _unused_accepted;
        video_payload_t idle_payload;
        begin
            guard = 0;
            idle_payload = '0;
            while (output_count < target_count) begin
                step(1'b0, idle_payload, 1'b1, _unused_accepted);
                guard = guard + 1;
                check(guard < 128, "alignment FIFO did not drain");
            end
        end
    endtask

    video_payload_t payload;
    video_payload_t idle_payload;
    logic accepted;
    logic [7:0] index_value;
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

        // Fill the complete FIFO while the join is stalled.
        reset_dut();
        for (index = 0; index < ALIGNMENT_DEPTH; index = index + 1) begin
            index_value = index[7:0];
            payload = make_payload(
                index_value,
                index == 0,
                (index % 3) == 2,
                index == (ALIGNMENT_DEPTH - 1),
                (index == 0) || (index == (ALIGNMENT_DEPTH - 1))
            );
            accepted = 1'b0;
            while (!accepted) begin
                step(1'b1, payload, 1'b0, accepted);
            end
        end
        check(
            accepted_count == ALIGNMENT_DEPTH,
            "FIFO did not accept its documented capacity"
        );

        // No pop means a full FIFO must backpressure the fork.
        payload = make_payload(8'd100, 1'b0, 1'b0, 1'b0, 1'b0);
        step(1'b1, payload, 1'b0, accepted);
        check(!accepted, "full alignment FIFO accepted without a pop");

        // A simultaneous pop and push at full occupancy must remain lossless.
        step(1'b1, payload, 1'b1, accepted);
        check(accepted, "simultaneous full-FIFO pop/push was not accepted");
        wait_for_outputs(ALIGNMENT_DEPTH + 1);
        check(
            expected_payloads.size() == 0,
            "full-FIFO test lost or duplicated a token"
        );
        check(!m_axis_tvalid, "full-FIFO test emitted an extra token");

        // Independent source bubbles and join stalls exercise pointer wrapping.
        reset_dut();
        for (index = 0; index < 24; index = index + 1) begin
            if ((index % 5) == 2) begin
                step(1'b0, idle_payload, 1'b0, accepted);
            end

            index_value = index[7:0] + 8'd32;
            payload = make_payload(
                index_value,
                index == 0,
                (index % 6) == 5,
                index == 23,
                (index % 4) == 0
            );
            send_payload(payload, 1'b1);
        end
        wait_for_outputs(24);
        check(accepted_count == 24, "wrapped input count mismatch");
        check(expected_payloads.size() == 0, "wrapped output count mismatch");

        // Reset flushes validity and pointers without clearing the BRAM array.
        reset_dut();
        send_payload(
            make_payload(8'd180, 1'b1, 1'b0, 1'b0, 1'b1),
            1'b0
        );
        send_payload(
            make_payload(8'd181, 1'b0, 1'b0, 1'b0, 1'b0),
            1'b0
        );
        send_payload(
            make_payload(8'd182, 1'b0, 1'b1, 1'b1, 1'b1),
            1'b0
        );
        reset_dut();

        payload = make_payload(8'd220, 1'b1, 1'b1, 1'b1, 1'b1);
        send_payload(payload, 1'b0);
        wait_for_outputs(1);
        check(accepted_count == 1, "post-reset input count mismatch");
        check(expected_payloads.size() == 0, "stale payload escaped reset");
        check(!m_axis_tvalid, "post-reset test emitted an extra token");

        $display("stream_align_delay_tb: PASS");
        $finish;
    end

endmodule
