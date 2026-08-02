`timescale 1ns/1ps

module sobel_gx_gy_tb;

    logic aclk;
    logic aresetn;

    logic [71:0] s_window;
    logic [7:0] s_window_p00;
    logic [7:0] s_window_p01;
    logic [7:0] s_window_p02;
    logic [7:0] s_window_p10;
    logic [7:0] s_window_p11;
    logic [7:0] s_window_p12;
    logic [7:0] s_window_p20;
    logic [7:0] s_window_p21;
    logic [7:0] s_window_p22;
    logic s_window_valid;
    logic s_window_ready;

    logic signed [11:0] m_gradient_gx;
    logic signed [11:0] m_gradient_gy;
    logic m_gradient_valid;
    logic m_gradient_ready;

    logic [23:0] expected_gradients[$];
    logic [23:0] held_gradients;
    logic output_was_stalled;
    integer cycle_index;
    integer accepted_count;
    integer output_count;

    assign {
        s_window_p00,
        s_window_p01,
        s_window_p02,
        s_window_p10,
        s_window_p11,
        s_window_p12,
        s_window_p20,
        s_window_p21,
        s_window_p22
    } = s_window;

    sobel_gx_gy dut (
        .aclk,
        .aresetn,
        .s_window_p00,
        .s_window_p01,
        .s_window_p02,
        .s_window_p10,
        .s_window_p11,
        .s_window_p12,
        .s_window_p20,
        .s_window_p21,
        .s_window_p22,
        .s_window_valid,
        .s_window_ready,
        .m_gradient_gx,
        .m_gradient_gy,
        .m_gradient_valid,
        .m_gradient_ready
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

    function automatic logic [71:0] make_window(
        input logic [7:0] p00,
        input logic [7:0] p01,
        input logic [7:0] p02,
        input logic [7:0] p10,
        input logic [7:0] p11,
        input logic [7:0] p12,
        input logic [7:0] p20,
        input logic [7:0] p21,
        input logic [7:0] p22
    );
        begin
            make_window = {
                p00,
                p01,
                p02,
                p10,
                p11,
                p12,
                p20,
                p21,
                p22
            };
        end
    endfunction

    function automatic logic [23:0] expected_gradient(
        input logic [71:0] samples
    );
        logic [7:0] p00;
        logic [7:0] p01;
        logic [7:0] p02;
        logic [7:0] p10;
        logic [7:0] p11;
        logic [7:0] p12;
        logic [7:0] p20;
        logic [7:0] p21;
        logic [7:0] p22;
        logic _unused_center;
        integer gx;
        integer gy;
        logic [11:0] gx_12bit;
        logic [11:0] gy_12bit;
        logic [19:0] _unused_gx_high;
        logic [19:0] _unused_gy_high;
        begin
            {
                p00,
                p01,
                p02,
                p10,
                p11,
                p12,
                p20,
                p21,
                p22
            } = samples;

            gx =
                -int'(p00) + int'(p02)
                - (2 * int'(p10)) + (2 * int'(p12))
                - int'(p20) + int'(p22);
            gy =
                int'(p00) + (2 * int'(p01)) + int'(p02)
                - int'(p20) - (2 * int'(p21)) - int'(p22);
            {_unused_gx_high, gx_12bit} = gx;
            {_unused_gy_high, gy_12bit} = gy;
            expected_gradient = {gx_12bit, gy_12bit};
            _unused_center = &{1'b0, p11};
        end
    endfunction

    function automatic logic [23:0] current_gradients;
        begin
            current_gradients = {m_gradient_gx, m_gradient_gy};
        end
    endfunction

    task automatic step(
        input logic source_valid,
        input logic [71:0] source_window,
        input logic sink_ready,
        output logic input_accepted
    );
        logic output_accepted;
        logic [23:0] expected;
        integer current_gx;
        integer current_gy;
        begin
            @(negedge aclk);
            s_window_valid = source_valid;
            s_window = source_window;
            m_gradient_ready = sink_ready;
            #1;

            input_accepted = source_valid && s_window_ready;
            output_accepted = m_gradient_valid && sink_ready;

            if (output_was_stalled) begin
                check(
                    m_gradient_valid,
                    "gradient valid dropped while stalled"
                );
                check(
                    current_gradients() === held_gradients,
                    "gradient values changed while stalled"
                );
            end

            if (m_gradient_valid) begin
                current_gx = $signed({
                    {20{m_gradient_gx[11]}},
                    m_gradient_gx
                });
                current_gy = $signed({
                    {20{m_gradient_gy[11]}},
                    m_gradient_gy
                });
                check(
                    (current_gx >= -1020) && (current_gx <= 1020),
                    "Gx exceeded the legal signed range"
                );
                check(
                    (current_gy >= -1020) && (current_gy <= 1020),
                    "Gy exceeded the legal signed range"
                );
            end

            if (m_gradient_valid && !sink_ready) begin
                if (!output_was_stalled) begin
                    held_gradients = current_gradients();
                end
                output_was_stalled = 1'b1;
            end else begin
                output_was_stalled = 1'b0;
            end

            if (output_accepted) begin
                check(
                    expected_gradients.size() != 0,
                    "Sobel pipeline emitted an unexpected result"
                );
                expected = expected_gradients.pop_front();
                check(
                    current_gradients() === expected,
                    "Sobel gradient value or ordering mismatch"
                );
                output_count = output_count + 1;
            end

            if (input_accepted) begin
                expected_gradients.push_back(
                    expected_gradient(source_window)
                );
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
            s_window = 72'd0;
            s_window_valid = 1'b0;
            m_gradient_ready = 1'b0;
            expected_gradients.delete();
            output_was_stalled = 1'b0;
            cycle_index = 0;
            accepted_count = 0;
            output_count = 0;

            repeat (2) @(posedge aclk);
            #1;
            check(
                !m_gradient_valid,
                "gradient valid remained asserted after reset"
            );
            check(s_window_ready, "Sobel input was not ready after reset");

            @(negedge aclk);
            aresetn = 1'b1;
            #1;
        end
    endtask

    task automatic send_window(
        input logic [71:0] samples,
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
                        && ((cycle_index % 7) != 0)
                    );
                step(1'b1, samples, sink_ready, accepted);
            end
        end
    endtask

    task automatic wait_for_outputs(input integer target_count);
        integer guard;
        logic _unused_accepted;
        begin
            guard = 0;
            while (output_count < target_count) begin
                step(1'b0, 72'd0, 1'b1, _unused_accepted);
                guard = guard + 1;
                check(guard < 64, "Sobel pipeline did not drain");
            end
        end
    endtask

    logic _unused_accepted;
    logic [7:0] index_value;
    integer index;

    initial begin
        aresetn = 1'b0;
        s_window = 72'd0;
        s_window_valid = 1'b0;
        m_gradient_ready = 1'b0;
        output_was_stalled = 1'b0;
        cycle_index = 0;
        accepted_count = 0;
        output_count = 0;

        reset_dut();

        // Flat fields must produce zero on both axes.
        send_window({9{8'd0}}, 1'b0);
        send_window({9{8'd137}}, 1'b0);

        // Vertical edges exercise the exact positive and negative Gx extrema.
        send_window(
            make_window(
                0, 0, 255,
                0, 0, 255,
                0, 0, 255
            ),
            1'b0
        );
        send_window(
            make_window(
                255, 0, 0,
                255, 0, 0,
                255, 0, 0
            ),
            1'b0
        );

        // Horizontal edges exercise the exact positive and negative Gy extrema.
        send_window(
            make_window(
                255, 255, 255,
                0, 0, 0,
                0, 0, 0
            ),
            1'b0
        );
        send_window(
            make_window(
                0, 0, 0,
                0, 0, 0,
                255, 255, 255
            ),
            1'b0
        );

        // Diagonal patterns cross both gradient signs at magnitude 765.
        send_window(
            make_window(
                0, 255, 255,
                0, 0, 255,
                0, 0, 0
            ),
            1'b0
        );
        send_window(
            make_window(
                255, 0, 0,
                255, 255, 0,
                255, 255, 255
            ),
            1'b0
        );

        wait_for_outputs(8);
        check(accepted_count == 8, "directed input count mismatch");
        check(expected_gradients.size() == 0, "directed output count mismatch");
        check(!m_gradient_valid, "directed test emitted an extra result");

        // Bubbles and downstream stalls must preserve data and ordering.
        reset_dut();
        for (index = 0; index < 12; index = index + 1) begin
            if ((index % 3) == 1) begin
                step(1'b0, 72'd0, 1'b0, _unused_accepted);
            end
            index_value = index[7:0];
            send_window(
                make_window(
                    index_value,
                    index_value + 8'd11,
                    index_value + 8'd22,
                    index_value + 8'd33,
                    index_value + 8'd44,
                    index_value + 8'd55,
                    index_value + 8'd66,
                    index_value + 8'd77,
                    index_value + 8'd88
                ),
                1'b1
            );
        end
        wait_for_outputs(12);
        check(accepted_count == 12, "stalled input count mismatch");
        check(expected_gradients.size() == 0, "stalled output count mismatch");

        // Hold a full output stage stalled for several clocks.
        reset_dut();
        send_window(
            make_window(
                0, 0, 255,
                0, 0, 255,
                0, 0, 255
            ),
            1'b0
        );
        send_window(
            make_window(
                255, 255, 255,
                0, 0, 0,
                0, 0, 0
            ),
            1'b0
        );
        repeat (4) begin
            step(1'b0, 72'd0, 1'b0, _unused_accepted);
        end
        wait_for_outputs(2);
        check(expected_gradients.size() == 0, "long-stall output mismatch");
        check(!m_gradient_valid, "long-stall test emitted an extra result");

        $display("sobel_gx_gy_tb: PASS");
        $finish;
    end

endmodule
