`timescale 1ns/1ps

module sobel_magnitude_tb;

    logic aclk;
    logic aresetn;

    logic signed [11:0] s_gradient_gx;
    logic signed [11:0] s_gradient_gy;
    logic s_gradient_valid;
    logic s_gradient_ready;
    logic [7:0] active_threshold;

    logic [7:0] m_sobel_magnitude;
    logic [7:0] m_sobel_edge;
    logic m_sobel_valid;
    logic m_sobel_ready;

    logic [15:0] expected_results[$];
    logic [15:0] held_result;
    logic output_was_stalled;
    integer cycle_index;
    integer accepted_count;
    integer output_count;

    sobel_magnitude dut (
        .aclk,
        .aresetn,
        .s_gradient_gx,
        .s_gradient_gy,
        .s_gradient_valid,
        .s_gradient_ready,
        .active_threshold,
        .m_sobel_magnitude,
        .m_sobel_edge,
        .m_sobel_valid,
        .m_sobel_ready
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

    function automatic logic [15:0] expected_result(
        input logic signed [11:0] gx,
        input logic signed [11:0] gy,
        input logic [7:0] threshold
    );
        integer gx_integer;
        integer gy_integer;
        integer gx_absolute;
        integer gy_absolute;
        integer magnitude;
        integer scaled_threshold;
        logic [7:0] magnitude_8bit;
        logic [7:0] edge_value;
        begin
            gx_integer = $signed({{20{gx[11]}}, gx});
            gy_integer = $signed({{20{gy[11]}}, gy});
            gx_absolute =
                (gx_integer < 0) ? -gx_integer : gx_integer;
            gy_absolute =
                (gy_integer < 0) ? -gy_integer : gy_integer;
            magnitude = gx_absolute + gy_absolute;
            scaled_threshold = int'(threshold) * 6;

            magnitude_8bit =
                (magnitude > 255) ? 8'hff : magnitude[7:0];
            edge_value =
                (magnitude > scaled_threshold) ? 8'hff : 8'h00;
            expected_result = {magnitude_8bit, edge_value};
        end
    endfunction

    function automatic logic [15:0] current_result;
        begin
            current_result = {m_sobel_magnitude, m_sobel_edge};
        end
    endfunction

    task automatic step(
        input logic source_valid,
        input logic signed [11:0] source_gx,
        input logic signed [11:0] source_gy,
        input logic [7:0] source_threshold,
        input logic sink_ready,
        output logic input_accepted
    );
        logic output_accepted;
        logic [15:0] expected;
        begin
            @(negedge aclk);
            s_gradient_valid = source_valid;
            s_gradient_gx = source_gx;
            s_gradient_gy = source_gy;
            active_threshold = source_threshold;
            m_sobel_ready = sink_ready;
            #1;

            input_accepted = source_valid && s_gradient_ready;
            output_accepted = m_sobel_valid && sink_ready;

            if (output_was_stalled) begin
                check(m_sobel_valid, "Sobel valid dropped while stalled");
                check(
                    current_result() === held_result,
                    "Sobel result changed while stalled"
                );
            end

            if (m_sobel_valid) begin
                check(
                    (m_sobel_edge == 8'h00)
                        || (m_sobel_edge == 8'hff),
                    "edge result was not binary"
                );
            end

            if (m_sobel_valid && !sink_ready) begin
                if (!output_was_stalled) begin
                    held_result = current_result();
                end
                output_was_stalled = 1'b1;
            end else begin
                output_was_stalled = 1'b0;
            end

            if (output_accepted) begin
                check(
                    expected_results.size() != 0,
                    "magnitude pipeline emitted an unexpected result"
                );
                expected = expected_results.pop_front();
                check(
                    current_result() === expected,
                    "magnitude, edge, or output ordering mismatch"
                );
                output_count = output_count + 1;
            end

            if (input_accepted) begin
                expected_results.push_back(
                    expected_result(
                        source_gx,
                        source_gy,
                        source_threshold
                    )
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
            s_gradient_gx = 12'sd0;
            s_gradient_gy = 12'sd0;
            s_gradient_valid = 1'b0;
            active_threshold = 8'd0;
            m_sobel_ready = 1'b0;
            expected_results.delete();
            output_was_stalled = 1'b0;
            cycle_index = 0;
            accepted_count = 0;
            output_count = 0;

            repeat (2) @(posedge aclk);
            #1;
            check(
                !m_sobel_valid,
                "Sobel valid remained asserted after reset"
            );
            check(
                s_gradient_ready,
                "magnitude input was not ready after reset"
            );

            @(negedge aclk);
            aresetn = 1'b1;
            #1;
        end
    endtask

    task automatic send_gradient(
        input logic signed [11:0] gx,
        input logic signed [11:0] gy,
        input logic [7:0] threshold,
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
                step(
                    1'b1,
                    gx,
                    gy,
                    threshold,
                    sink_ready,
                    accepted
                );
            end
        end
    endtask

    task automatic wait_for_outputs(input integer target_count);
        integer guard;
        logic _unused_accepted;
        begin
            guard = 0;
            while (output_count < target_count) begin
                step(
                    1'b0,
                    12'sd0,
                    12'sd0,
                    8'd0,
                    1'b1,
                    _unused_accepted
                );
                guard = guard + 1;
                check(guard < 64, "magnitude pipeline did not drain");
            end
        end
    endtask

    logic _unused_accepted;

    initial begin
        aresetn = 1'b0;
        s_gradient_gx = 12'sd0;
        s_gradient_gy = 12'sd0;
        s_gradient_valid = 1'b0;
        active_threshold = 8'd0;
        m_sobel_ready = 1'b0;
        output_was_stalled = 1'b0;
        cycle_index = 0;
        accepted_count = 0;
        output_count = 0;

        reset_dut();

        // Absolute-value zero, positive, and negative corner cases.
        send_gradient(12'sd0, 12'sd0, 8'd0, 1'b0);
        send_gradient(12'sd1, 12'sd0, 8'd0, 1'b0);
        send_gradient(-12'sd1, 12'sd0, 8'd0, 1'b0);
        send_gradient(12'sd0, -12'sd1020, 8'd170, 1'b0);

        // Saturation boundary at magnitudes 254, 255, and 256.
        send_gradient(12'sd254, 12'sd0, 8'd255, 1'b0);
        send_gradient(12'sd255, 12'sd0, 8'd255, 1'b0);
        send_gradient(12'sd256, 12'sd0, 8'd255, 1'b0);

        // Threshold 1 scales to 6: below/equal are zero, above is an edge.
        send_gradient(12'sd5, 12'sd0, 8'd1, 1'b0);
        send_gradient(12'sd6, 12'sd0, 8'd1, 1'b0);
        send_gradient(12'sd7, 12'sd0, 8'd1, 1'b0);

        // Reachable maximum 1530 is equal to threshold 255 * 6.
        send_gradient(12'sd765, 12'sd765, 8'd255, 1'b0);
        send_gradient(-12'sd765, -12'sd765, 8'd254, 1'b0);

        // Single-axis extremum checks strict equality and above-threshold cases.
        send_gradient(12'sd1020, 12'sd0, 8'd170, 1'b0);
        send_gradient(-12'sd1020, 12'sd0, 8'd169, 1'b0);

        wait_for_outputs(14);
        check(accepted_count == 14, "directed input count mismatch");
        check(expected_results.size() == 0, "directed output count mismatch");
        check(!m_sobel_valid, "directed test emitted an extra result");

        // Back-to-back threshold changes, bubbles, and output backpressure.
        reset_dut();
        send_gradient(12'sd321, -12'sd123, 8'd0, 1'b1);
        step(
            1'b0,
            12'sd0,
            12'sd0,
            8'd0,
            1'b0,
            _unused_accepted
        );
        send_gradient(-12'sd400, 12'sd200, 8'd99, 1'b1);
        send_gradient(12'sd512, -12'sd256, 8'd127, 1'b1);
        step(
            1'b0,
            12'sd0,
            12'sd0,
            8'd0,
            1'b0,
            _unused_accepted
        );
        send_gradient(-12'sd17, -12'sd29, 8'd7, 1'b1);
        send_gradient(12'sd700, 12'sd100, 8'd133, 1'b1);
        send_gradient(-12'sd600, 12'sd300, 8'd150, 1'b1);
        wait_for_outputs(6);
        check(accepted_count == 6, "stalled input count mismatch");
        check(expected_results.size() == 0, "stalled output count mismatch");

        // A full output stage must retain both magnitude and edge while stalled.
        reset_dut();
        send_gradient(12'sd765, 12'sd765, 8'd254, 1'b0);
        send_gradient(-12'sd1020, 12'sd0, 8'd170, 1'b0);
        repeat (4) begin
            step(
                1'b0,
                12'sd0,
                12'sd0,
                8'd0,
                1'b0,
                _unused_accepted
            );
        end
        wait_for_outputs(2);
        check(expected_results.size() == 0, "long-stall output mismatch");
        check(!m_sobel_valid, "long-stall test emitted an extra result");

        $display("sobel_magnitude_tb: PASS");
        $finish;
    end

endmodule
