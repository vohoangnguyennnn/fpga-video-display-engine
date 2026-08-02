`timescale 1ns/1ps

module button_control_tb;

    localparam time CLK_PERIOD = 10ns;
    localparam integer DEBOUNCE_CYCLES = 3;
    localparam integer SETTLE_CYCLES = DEBOUNCE_CYCLES + 3;
    localparam logic [7:0] THRESHOLD_STEP = 8'd32;

    localparam logic MODE_BUTTON = 1'd0;
    localparam logic THRESHOLD_UP_BUTTON = 1'd1;

    logic pix_clk;
    logic pix_reset;
    logic [1:0] buttons;
    logic [1:0] cfg_mode;
    logic [7:0] cfg_threshold;

    button_control #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),
        .THRESHOLD_STEP(THRESHOLD_STEP)
    ) dut (
        .pix_clk,
        .pix_reset,
        .btn_mode(buttons[MODE_BUTTON]),
        .btn_threshold_up(buttons[THRESHOLD_UP_BUTTON]),
        .cfg_mode,
        .cfg_threshold
    );

    always #(CLK_PERIOD / 2) pix_clk = !pix_clk;

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $fatal(1, "CHECK FAILED: %s", message);
        end
    endtask

    task automatic wait_pixel_edges(input integer edge_count);
        repeat (edge_count) @(posedge pix_clk);
        #1ps;
    endtask

    task automatic press_and_release(input logic button_index);
        @(negedge pix_clk);
        buttons[button_index] = 1'b1;
        wait_pixel_edges(SETTLE_CYCLES);

        @(negedge pix_clk);
        buttons[button_index] = 1'b0;
        wait_pixel_edges(SETTLE_CYCLES);
    endtask

    initial begin
        pix_clk = 1'b0;
        pix_reset = 1'b1;
        buttons = '0;

        wait_pixel_edges(2);
        check(cfg_mode == 2'd0, "reset did not select pass-through mode");
        check(cfg_threshold == 8'd0, "reset did not clear threshold");

        @(negedge pix_clk);
        pix_reset = 1'b0;

        // A synchronized high pulse shorter than the debounce interval must
        // not create a mode event.
        @(negedge pix_clk);
        buttons[MODE_BUTTON] = 1'b1;
        wait_pixel_edges(1);
        @(negedge pix_clk);
        buttons[MODE_BUTTON] = 1'b0;
        wait_pixel_edges(SETTLE_CYCLES + 2);
        check(cfg_mode == 2'd0, "short button pulse passed the debounce filter");

        // Contact bounce before the stable press must still create exactly
        // one mode change.
        @(negedge pix_clk);
        buttons[MODE_BUTTON] = 1'b1;
        wait_pixel_edges(1);
        @(negedge pix_clk);
        buttons[MODE_BUTTON] = 1'b0;
        wait_pixel_edges(1);
        @(negedge pix_clk);
        buttons[MODE_BUTTON] = 1'b1;
        wait_pixel_edges(SETTLE_CYCLES);
        check(cfg_mode == 2'd1, "stable bounced press did not advance mode");

        wait_pixel_edges(SETTLE_CYCLES * 2);
        check(cfg_mode == 2'd1, "held mode button generated repeated events");

        @(negedge pix_clk);
        buttons[MODE_BUTTON] = 1'b0;
        wait_pixel_edges(SETTLE_CYCLES);

        // Complete the four-mode cycle.
        press_and_release(MODE_BUTTON);
        check(cfg_mode == 2'd2, "mode 1 did not advance to mode 2");
        press_and_release(MODE_BUTTON);
        check(cfg_mode == 2'd3, "mode 2 did not advance to mode 3");
        press_and_release(MODE_BUTTON);
        check(cfg_mode == 2'd0, "mode 3 did not wrap to mode 0");

        // A held threshold button also produces only one adjustment.
        @(negedge pix_clk);
        buttons[THRESHOLD_UP_BUTTON] = 1'b1;
        wait_pixel_edges(SETTLE_CYCLES);
        check(cfg_threshold == 8'd32, "threshold preset press was not accepted");
        wait_pixel_edges(SETTLE_CYCLES * 2);
        check(cfg_threshold == 8'd32, "held threshold button auto-repeated");
        @(negedge pix_clk);
        buttons[THRESHOLD_UP_BUTTON] = 1'b0;
        wait_pixel_edges(SETTLE_CYCLES);

        press_and_release(THRESHOLD_UP_BUTTON);
        check(cfg_threshold == 8'd64, "second threshold preset was missed");

        // Exercise the board's eight-value preset sequence and modular wrap.
        for (integer press_index = 2; press_index < 7; press_index++) begin
            press_and_release(THRESHOLD_UP_BUTTON);
        end
        check(cfg_threshold == 8'd224, "threshold did not reach preset 224");

        press_and_release(THRESHOLD_UP_BUTTON);
        check(cfg_threshold == 8'd0, "threshold presets did not wrap to zero");

        // Reset also clears any debounced/edge history, not just configuration.
        @(negedge pix_clk);
        pix_reset = 1'b1;
        wait_pixel_edges(2);
        check(cfg_mode == 2'd0, "reset did not clear mode after operation");
        check(cfg_threshold == 8'd0, "reset did not clear threshold after operation");

        $display("button_control_tb: PASS");
        $finish;
    end

endmodule
