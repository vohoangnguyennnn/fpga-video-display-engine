// Build-time diagnostic monitor for the fixed DDR framebuffer path.
//
// One measurement starts on a successful framebuffer swap, when the
// controller launches the next concurrent WDMA/RDMA pair.  The monitor counts
// only accepted AXI data beats and includes command, fabric, MIG, FIFO, and
// final-response time by stopping when both DMA engines report terminal
// completion.  Snapshot outputs remain stable until the next measurement
// completes so they can be captured by an optional UI-clocked ILA.
//
// This block is observation-only: no output feeds DMA, ownership, or AXI flow
// control.  The board integration instantiates it only in the diagnostic
// performance build; it is not a permanent AXI performance-monitor IP.

module framebuffer_perf_monitor #(
    parameter integer FRAME_BYTES = 3_686_400,
    parameter integer AXI_DATA_BYTES = 16,
    // At 100 MHz, two 3,686,400-byte frames transferred in no more than
    // 1,333,333 cycles exceed the 552,960,000 byte/s release threshold.
    parameter integer MAX_WINDOW_CYCLES = 1_333_333
) (
    input  logic        ui_clk,
    input  logic        ui_reset,

    // UI-domain framebuffer-controller events.
    input  logic        swap_start,
    input  logic        repeat_frame,

    // WDMA/RDMA data-channel handshakes at the AXI-interconnect boundary.
    input  logic        write_data_valid,
    input  logic        write_data_ready,
    input  logic        read_data_valid,
    input  logic        read_data_ready,

    // Terminal status for the pair launched by swap_start.  read_fetch_done
    // is used rather than final stream consumption because this monitor
    // measures external-memory payload movement.
    input  logic        write_frame_done,
    input  logic        write_frame_success,
    input  logic        read_fetch_done,
    input  logic        read_fetch_success,

    // Stable measurement snapshot for ILA/debug capture.
    output logic        debug_measurement_active,
    output logic        debug_measurement_valid,
    output logic        debug_bandwidth_pass,
    output logic [31:0] debug_window_cycles,
    output logic [31:0] debug_write_beats,
    output logic [31:0] debug_read_beats,
    output logic [31:0] debug_write_stall_cycles,
    output logic [31:0] debug_read_stall_cycles,
    output logic [31:0] debug_measurement_count,

    // Compact swap/repeat evidence required by the framebuffer release plan.
    output logic        debug_swap_interval_valid,
    output logic [31:0] debug_swap_interval_cycles,
    output logic [31:0] debug_swap_count,
    output logic [31:0] debug_repeat_count
);

    localparam integer FRAME_BEATS = FRAME_BYTES / AXI_DATA_BYTES;
    localparam logic [31:0] FRAME_BEATS_VALUE = 32'(FRAME_BEATS);
    localparam logic [31:0] MAX_WINDOW_CYCLES_VALUE = 32'(MAX_WINDOW_CYCLES);

    logic [31:0] active_cycles_q;
    logic [31:0] write_beats_q;
    logic [31:0] read_beats_q;
    logic [31:0] write_stall_cycles_q;
    logic [31:0] read_stall_cycles_q;
    logic        write_done_seen_q;
    logic        read_done_seen_q;
    logic        write_success_q;
    logic        read_success_q;

    logic        swap_seen_q;
    logic [31:0] swap_interval_counter_q;

    logic        write_transfer;
    logic        read_transfer;
    logic        write_stall;
    logic        read_stall;
    logic [31:0] next_active_cycles;
    logic [31:0] next_write_beats;
    logic [31:0] next_read_beats;
    logic [31:0] next_write_stall_cycles;
    logic [31:0] next_read_stall_cycles;
    logic        write_done_now;
    logic        read_done_now;
    logic        write_success_now;
    logic        read_success_now;
    logic        measurement_complete;

    function automatic logic [31:0] saturating_increment(
        input logic [31:0] value
    );
        begin
            saturating_increment = (&value) ? value : value + 32'd1;
        end
    endfunction

    initial begin
        assert (FRAME_BYTES > 0)
            else $fatal(1,"framebuffer_perf_monitor FRAME_BYTES must be positive");
        assert (AXI_DATA_BYTES > 0)
            else $fatal(1,"framebuffer_perf_monitor AXI_DATA_BYTES must be positive");
        assert ((FRAME_BYTES % AXI_DATA_BYTES) == 0)
            else $fatal(1,"framebuffer_perf_monitor frame must contain whole AXI beats");
        assert (FRAME_BEATS > 0)
            else $fatal(1,"framebuffer_perf_monitor FRAME_BEATS must be positive");
        assert (MAX_WINDOW_CYCLES > 0)
            else $fatal(1,"framebuffer_perf_monitor MAX_WINDOW_CYCLES must be positive");
    end

    assign write_transfer = write_data_valid && write_data_ready;
    assign read_transfer = read_data_valid && read_data_ready;
    assign write_stall = write_data_valid && !write_data_ready;
    assign read_stall = read_data_valid && !read_data_ready;

    assign next_active_cycles = saturating_increment(active_cycles_q);
    assign next_write_beats = write_transfer ? saturating_increment(write_beats_q) : write_beats_q;
    assign next_read_beats = read_transfer ? saturating_increment(read_beats_q) : read_beats_q;
    assign next_write_stall_cycles = write_stall ? saturating_increment(write_stall_cycles_q) : write_stall_cycles_q;
    assign next_read_stall_cycles = read_stall ? saturating_increment(read_stall_cycles_q) : read_stall_cycles_q;

    assign write_done_now = write_done_seen_q || write_frame_done;
    assign read_done_now = read_done_seen_q || read_fetch_done;
    assign write_success_now = write_success_q && (!write_frame_done || write_frame_success);
    assign read_success_now = read_success_q && (!read_fetch_done || read_fetch_success);
    assign measurement_complete = debug_measurement_active && write_done_now && read_done_now;

    always_ff @(posedge ui_clk) begin
        if (ui_reset) begin
            debug_measurement_active <= 1'b0;
            debug_measurement_valid <= 1'b0;
            debug_bandwidth_pass <= 1'b0;
            debug_window_cycles <= 32'd0;
            debug_write_beats <= 32'd0;
            debug_read_beats <= 32'd0;
            debug_write_stall_cycles <= 32'd0;
            debug_read_stall_cycles <= 32'd0;
            debug_measurement_count <= 32'd0;

            active_cycles_q <= 32'd0;
            write_beats_q <= 32'd0;
            read_beats_q <= 32'd0;
            write_stall_cycles_q <= 32'd0;
            read_stall_cycles_q <= 32'd0;
            write_done_seen_q <= 1'b0;
            read_done_seen_q <= 1'b0;
            write_success_q <= 1'b1;
            read_success_q <= 1'b1;

            swap_seen_q <= 1'b0;
            swap_interval_counter_q <= 32'd0;
            debug_swap_interval_valid <= 1'b0;
            debug_swap_interval_cycles <= 32'd0;
            debug_swap_count <= 32'd0;
            debug_repeat_count <= 32'd0;
        end else begin
            if (swap_start) begin
                debug_swap_count <= saturating_increment(debug_swap_count);

                if (swap_seen_q) begin
                    debug_swap_interval_cycles <= saturating_increment(swap_interval_counter_q);
                    debug_swap_interval_valid <= 1'b1;
                end else begin
                    swap_seen_q <= 1'b1;
                end
                swap_interval_counter_q <= 32'd0;
            end else if (swap_seen_q) begin
                swap_interval_counter_q <= saturating_increment(swap_interval_counter_q);
            end

            if (repeat_frame) begin
                debug_repeat_count <= saturating_increment(debug_repeat_count);
            end

            // A legal controller does not issue another swap until the
            // current read/write pair has reached its terminal state. Ignore
            // an overlapping start rather than corrupting the active sample.
            if (swap_start && !debug_measurement_active) begin
                debug_measurement_active <= 1'b1;
                active_cycles_q <= 32'd0;
                write_beats_q <= write_transfer ? 32'd1 : 32'd0;
                read_beats_q <= read_transfer ? 32'd1 : 32'd0;
                write_stall_cycles_q <= write_stall ? 32'd1 : 32'd0;
                read_stall_cycles_q <= read_stall ? 32'd1 : 32'd0;
                write_done_seen_q <= write_frame_done;
                read_done_seen_q <= read_fetch_done;
                write_success_q <= !write_frame_done || write_frame_success;
                read_success_q <= !read_fetch_done || read_fetch_success;
            end else if (debug_measurement_active) begin
                active_cycles_q <= next_active_cycles;
                write_beats_q <= next_write_beats;
                read_beats_q <= next_read_beats;
                write_stall_cycles_q <= next_write_stall_cycles;
                read_stall_cycles_q <= next_read_stall_cycles;
                write_done_seen_q <= write_done_now;
                read_done_seen_q <= read_done_now;
                write_success_q <= write_success_now;
                read_success_q <= read_success_now;

                if (measurement_complete) begin
                    debug_measurement_active <= 1'b0;
                    debug_measurement_valid <= 1'b1;
                    debug_window_cycles <= next_active_cycles;
                    debug_write_beats <= next_write_beats;
                    debug_read_beats <= next_read_beats;
                    debug_write_stall_cycles <= next_write_stall_cycles;
                    debug_read_stall_cycles <= next_read_stall_cycles;
                    debug_measurement_count <= saturating_increment( debug_measurement_count);
                    debug_bandwidth_pass <= write_success_now
                        && read_success_now
                        && (next_write_beats == FRAME_BEATS_VALUE)
                        && (next_read_beats == FRAME_BEATS_VALUE)
                        && (next_active_cycles <= MAX_WINDOW_CYCLES_VALUE);
                end
            end
        end
    end

endmodule
