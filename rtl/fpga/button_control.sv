// Pixel-domain board-button control.
//
// The three active-high button inputs are asynchronous to pix_clk. Each input
// is first passed through a two-flop synchronizer, then accepted only after it
// has remained unchanged for DEBOUNCE_CYCLES consecutive pixel-clock edges.
// A held button produces one action; it must be released before another press.
//
// cfg_mode and cfg_threshold are pending configuration values. The processing
// core snapshots them on an accepted SOF, so frame-boundary commit logic does
// not belong in this module.

module button_control #(
    // 20 ms at the nominal 74.21875 MHz 720p pixel clock.
    parameter integer DEBOUNCE_CYCLES = 1_484_375
) (
    input logic pix_clk,
    input logic pix_reset,

    input logic btn_mode,
    input logic btn_threshold_up,
    input logic btn_threshold_down,

    output logic [1:0] cfg_mode,
    output logic [7:0] cfg_threshold
);

    localparam integer BUTTON_COUNT = 3;
    localparam integer MODE_BUTTON = 0;
    localparam integer THRESHOLD_UP_BUTTON = 1;
    localparam integer THRESHOLD_DOWN_BUTTON = 2;
    localparam integer COUNTER_WIDTH = (DEBOUNCE_CYCLES <= 1) ? 1 : $clog2(DEBOUNCE_CYCLES);
    localparam logic [COUNTER_WIDTH-1:0] DEBOUNCE_LAST = COUNTER_WIDTH'(DEBOUNCE_CYCLES - 1);

    logic [BUTTON_COUNT-1:0] button_async;

    // Prevent Vivado from absorbing either synchronizer stage into an SRL and
    // identify the registers for CDC-aware placement.
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [BUTTON_COUNT-1:0] button_meta_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [BUTTON_COUNT-1:0] button_sync_q;

    logic [BUTTON_COUNT-1:0] button_debounced_q;
    logic [BUTTON_COUNT-1:0] button_debounced_d_q;
    logic [BUTTON_COUNT-1:0] button_press;
    logic [COUNTER_WIDTH-1:0] debounce_count_q [0:BUTTON_COUNT-1];

    initial begin
        assert (DEBOUNCE_CYCLES >= 1)
            else $fatal(1, "button_control DEBOUNCE_CYCLES must be at least 1");
    end

    assign button_async[MODE_BUTTON] = btn_mode;
    assign button_async[THRESHOLD_UP_BUTTON] = btn_threshold_up;
    assign button_async[THRESHOLD_DOWN_BUTTON] = btn_threshold_down;
    assign button_press = button_debounced_q & ~button_debounced_d_q;

    // Synchronize the raw mechanical inputs into the pixel-clock domain.
    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            button_meta_q <= '0;
            button_sync_q <= '0;
        end else begin
            button_meta_q <= button_async;
            button_sync_q <= button_meta_q;
        end
    end

    // Each button has an independent stability counter so activity on one
    // button cannot delay or validate another button.
    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            button_debounced_q <= '0;
            button_debounced_d_q <= '0;

            for (integer button_index = 0; button_index < BUTTON_COUNT; button_index++) begin
                debounce_count_q[button_index] <= '0;
            end
        end else begin
            button_debounced_d_q <= button_debounced_q;

            for (integer button_index = 0; button_index < BUTTON_COUNT; button_index++) begin
                if (button_sync_q[button_index] == button_debounced_q[button_index]) begin
                    debounce_count_q[button_index] <= '0;
                end else if (DEBOUNCE_CYCLES == 1) begin
                    button_debounced_q[button_index] <= button_sync_q[button_index];
                    debounce_count_q[button_index] <= '0;
                end else if (debounce_count_q[button_index] == DEBOUNCE_LAST) begin
                    button_debounced_q[button_index] <= button_sync_q[button_index];
                    debounce_count_q[button_index] <= '0;
                end else begin
                    debounce_count_q[button_index] <= debounce_count_q[button_index] + 1'b1;
                end
            end
        end
    end

    // Mode 0..3 maps directly to pass-through, grayscale, Sobel magnitude,
    // and binary edge. Two-bit addition naturally wraps mode 3 back to 0.
    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            cfg_mode <= 2'd0;
            cfg_threshold <= 8'd0;
        end else begin
            if (button_press[MODE_BUTTON]) begin
                cfg_mode <= cfg_mode + 1'b1;
            end

            // Opposing simultaneous presses cancel. Otherwise adjustment is
            // saturating over the complete unsigned 8-bit threshold range.
            if (button_press[THRESHOLD_UP_BUTTON] && !button_press[THRESHOLD_DOWN_BUTTON]) begin
                if (cfg_threshold != 8'hff) begin
                    cfg_threshold <= cfg_threshold + 1'b1;
                end
            end else if (button_press[THRESHOLD_DOWN_BUTTON]
                && !button_press[THRESHOLD_UP_BUTTON]) begin
                if (cfg_threshold != 8'h00) begin
                    cfg_threshold <= cfg_threshold - 1'b1;
                end
            end
        end
    end

endmodule
