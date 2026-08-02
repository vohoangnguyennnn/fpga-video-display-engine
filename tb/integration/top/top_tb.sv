`timescale 1ns/1ps

module top_tb;

    localparam time CLK_50M_PERIOD = 20ns;
    localparam integer BUTTON_DEBOUNCE_CYCLES = 3;
    localparam integer BUTTON_SETTLE_CYCLES =
        BUTTON_DEBOUNCE_CYCLES + 4;
    localparam integer RASTER_FRAME_CYCLES = 1650 * 750;
    localparam integer LOCK_TIMEOUT_CYCLES = 2 * RASTER_FRAME_CYCLES;

    localparam logic MODE_KEY = 1'd0;
    localparam logic THRESHOLD_UP_KEY = 1'd1;

    logic clk_50m;
    logic [1:0] keys_n;
    logic [2:0] hdmi_data_p;
    logic [2:0] hdmi_data_n;
    logic hdmi_clk_p;
    logic hdmi_clk_n;
    logic led_frame_locked_n;
    logic led_fault_n;

    top #(
        .BUTTON_DEBOUNCE_CYCLES(BUTTON_DEBOUNCE_CYCLES)
    ) dut (
        .clk_50m,
        .key_mode_n(keys_n[MODE_KEY]),
        .key_threshold_up_n(keys_n[THRESHOLD_UP_KEY]),
        .hdmi_data_p,
        .hdmi_data_n,
        .hdmi_clk_p,
        .hdmi_clk_n,
        .led_frame_locked_n,
        .led_fault_n
    );

    always #(CLK_50M_PERIOD / 2) clk_50m = !clk_50m;

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $fatal(1, "CHECK FAILED: %s", message);
        end
    endtask

    task automatic wait_pixel_edges(input integer edge_count);
        repeat (edge_count) @(posedge dut.pix_clk);
        #1ps;
    endtask

    task automatic press_and_release(input logic key_index);
        @(negedge dut.pix_clk);
        keys_n[key_index] = 1'b0;
        wait_pixel_edges(BUTTON_SETTLE_CYCLES);

        @(negedge dut.pix_clk);
        keys_n[key_index] = 1'b1;
        wait_pixel_edges(BUTTON_SETTLE_CYCLES);
    endtask

    task automatic wait_for_frame_lock(output integer wait_cycles);
        wait_cycles = 0;
        while (led_frame_locked_n && (wait_cycles < LOCK_TIMEOUT_CYCLES)) begin
            @(posedge dut.pix_clk);
            wait_cycles++;
        end
        #1ps;
        check(!led_frame_locked_n, "raster did not acquire frame lock");
    endtask

    initial begin
        integer lock_wait_cycles;

        clk_50m = 1'b0;
        keys_n = '1;

        // The real MMCM starts unlocked. The simulation Clocking Wizard stub
        // models that startup and allows both reset conditioners to release.
        wait (dut.pix_reset);
        wait (!dut.pix_reset);
        #1ps;

        check(dut.cfg_mode == 2'd0, "top did not start in passthrough mode");
        check(dut.cfg_threshold == 8'd0, "top did not start at threshold zero");
        check(led_frame_locked_n, "frame-lock LED lit before raster lock");
        check(led_fault_n, "fault LED lit during clean startup");

        // Prove the active-low board-key inversion and control wiring.
        press_and_release(MODE_KEY);
        check(dut.cfg_mode == 2'd1, "K1 did not advance the processing mode");

        press_and_release(THRESHOLD_UP_KEY);
        check(dut.cfg_threshold == 8'd32, "K2 did not select threshold 32");

        // Seven more presses complete the eight-value preset cycle.
        repeat (7) press_and_release(THRESHOLD_UP_KEY);
        check(dut.cfg_threshold == 8'd0, "K2 threshold presets did not wrap");

        // Startup black is legal. The adapter must acquire only on a raster
        // frame boundary carrying a completed SOF line.
        wait_for_frame_lock(lock_wait_cycles);
        check(led_fault_n, "fault was raised while acquiring frame lock");

        // One complete locked frame must not produce any sticky integration
        // fault or return to black fallback.
        wait_pixel_edges(RASTER_FRAME_CYCLES);
        check(!led_frame_locked_n, "raster lost frame lock during clean flow");
        check(led_fault_n, "clean locked frame raised the aggregate fault LED");
        check(!dut.core_status_protocol_error, "core protocol error was raised");
        check(!dut.raster_status_overflow, "raster ownership overflow was raised");
        check(
            !dut.raster_status_malformed_line,
            "raster reported a malformed AXI line"
        );
        check(!dut.raster_status_underflow, "raster underflow was raised");
        check(
            !dut.raster_status_black_fallback,
            "raster entered black fallback after lock"
        );
        check(
            dut.u_video_stream_core.active_mode_q == dut.cfg_mode,
            "pending mode was not committed on a later accepted SOF"
        );
        check(
            dut.u_video_stream_core.active_threshold_q == dut.cfg_threshold,
            "pending threshold was not committed on a later accepted SOF"
        );

        // A generated-clock failure resets the complete board pipeline. After
        // lock returns, the same clean source must acquire a new frame without
        // leaving a sticky integration fault.
        @(negedge dut.pix_clk);
        dut.u_video_clock_reset.u_video_clk_wiz.force_lock_loss = 1'b1;
        wait (dut.pix_reset);
        @(posedge dut.pix_clk);
        #1ps;
        check(led_frame_locked_n, "frame lock remained set during clock loss");
        check(led_fault_n, "clock-loss reset raised a sticky fault");

        dut.u_video_clock_reset.u_video_clk_wiz.force_lock_loss = 1'b0;
        wait (!dut.pix_reset);
        #1ps;
        check(dut.cfg_mode == 2'd0, "clock-loss recovery did not reset mode");
        check(
            dut.cfg_threshold == 8'd0,
            "clock-loss recovery did not reset threshold"
        );

        wait_for_frame_lock(lock_wait_cycles);
        check(led_fault_n, "fault was raised while reacquiring frame lock");

        $display(
            "top_tb: PASS (frame reacquired after %0d pixel clocks)",
            lock_wait_cycles
        );
        $finish;
    end

endmodule
