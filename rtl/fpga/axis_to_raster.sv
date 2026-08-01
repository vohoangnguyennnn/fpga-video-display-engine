// AXI4-Stream RGB888 to fixed, non-stallable raster adapter.
//
// Two complete-line banks decouple the stallable processing stream from the
// fixed-rate raster. A bank is reserved before the first pixel of a line is
// accepted; once reserved, input ready remains asserted through the configured
// final pixel. TLAST is checked, but accepted-pixel count closes the line.
//
// The raster side locks only at a frame boundary carrying a completed SOF line.
// A missing line after lock makes the rest of that raster frame black and
// discards input until the next SOF. RAM contents are intentionally not reset.

module axis_to_raster #(
    parameter integer ACTIVE_WIDTH = 1280,
    parameter integer ACTIVE_HEIGHT = 720,
    parameter integer H_TOTAL = 1650,
    parameter integer V_TOTAL = 750
) (
    input logic pix_clk,
    input logic pix_reset,

    input logic [23:0] s_axis_tdata,
    input logic s_axis_tvalid,
    output logic s_axis_tready,
    input logic s_axis_tuser,
    input logic s_axis_tlast,

    input logic [10:0] h_count,
    input logic [9:0] v_count,
    input logic active_video,

    output logic [23:0] raster_rgb,

    output logic status_frame_locked,
    // Full banks cause legal AXI backpressure at a line boundary. Overflow is
    // reserved for an internal ownership conflict that would overwrite data.
    output logic status_overflow,
    output logic status_malformed_line,
    output logic status_underflow,
    output logic status_black_fallback
);

    localparam logic [10:0] ACTIVE_WIDTH_VALUE = ACTIVE_WIDTH[10:0];
    localparam logic [9:0] ACTIVE_HEIGHT_VALUE = ACTIVE_HEIGHT[9:0];
    localparam logic [10:0] H_TOTAL_VALUE = H_TOTAL[10:0];
    localparam logic [9:0] V_TOTAL_VALUE = V_TOTAL[9:0];
    localparam logic [10:0] LAST_ACTIVE_X = ACTIVE_WIDTH_VALUE - 1'b1;
    localparam logic [9:0] LAST_ACTIVE_Y = ACTIVE_HEIGHT_VALUE - 1'b1;
    localparam logic [10:0] LAST_RASTER_X = H_TOTAL_VALUE - 1'b1;
    localparam logic [9:0] LAST_RASTER_Y = V_TOTAL_VALUE - 1'b1;
    localparam integer ADDRESS_WIDTH = (ACTIVE_WIDTH <= 1) ? 1 : $clog2(ACTIVE_WIDTH);
    localparam logic [ADDRESS_WIDTH-1:0] LAST_WRITE_ADDRESS
        = ACTIVE_WIDTH_VALUE[ADDRESS_WIDTH-1:0] - 1'b1;

    (* ram_style = "block" *) logic [23:0] line_bank_0 [0:ACTIVE_WIDTH-1];
    (* ram_style = "block" *) logic [23:0] line_bank_1 [0:ACTIVE_WIDTH-1];

    logic [23:0] bank_0_read_data_q;
    logic [23:0] bank_1_read_data_q;
    logic read_data_valid_q;
    logic read_data_bank_q;

    logic [1:0] bank_complete_q;
    logic [1:0] bank_complete_n;
    logic [9:0] bank_0_line_q;
    logic [9:0] bank_0_line_n;
    logic [9:0] bank_1_line_q;
    logic [9:0] bank_1_line_n;
    logic [1:0] bank_sof_q;
    logic [1:0] bank_sof_n;

    logic write_active_q;
    logic write_active_n;
    logic write_bank_q;
    logic write_bank_n;
    logic [ADDRESS_WIDTH-1:0] write_column_q;
    logic [ADDRESS_WIDTH-1:0] write_column_n;
    logic [9:0] write_line_q;
    logic [9:0] write_line_n;
    logic write_sof_q;
    logic write_sof_n;

    logic source_hunting_q;
    logic source_hunting_n;
    logic [9:0] source_line_q;
    logic [9:0] source_line_n;

    logic read_bank_active_q;
    logic read_bank_active_n;
    logic read_bank_q;
    logic read_bank_n;
    logic frame_locked_q;
    logic frame_locked_n;
    logic lock_history_q;
    logic lock_history_n;

    logic status_overflow_q;
    logic status_overflow_n;
    logic status_malformed_line_q;
    logic status_malformed_line_n;
    logic status_underflow_q;
    logic status_underflow_n;
    logic status_black_fallback_q;
    logic status_black_fallback_n;

    logic bank_0_available;
    logic bank_1_available;
    logic empty_bank_valid;
    logic empty_bank_select;

    logic input_transfer;
    logic input_store;
    logic input_store_bank;
    logic [ADDRESS_WIDTH-1:0] input_store_address;
    logic input_bank_conflict;

    logic raster_line_boundary;
    logic [9:0] next_raster_line;
    logic next_line_is_active;
    logic bank_0_line_match;
    logic bank_1_line_match;
    logic display_select_valid;
    logic display_select_bank;

    logic read_request_valid;
    logic read_request_bank;
    logic [ADDRESS_WIDTH-1:0] read_request_address;

    initial begin
        assert ((ACTIVE_WIDTH >= 1) && (ACTIVE_WIDTH <= 2048))
            else $fatal(1, "ACTIVE_WIDTH must be in the range 1..2048");
        assert ((ACTIVE_HEIGHT >= 1) && (ACTIVE_HEIGHT <= 1024))
            else $fatal(1, "ACTIVE_HEIGHT must be in the range 1..1024");
        assert ((H_TOTAL > ACTIVE_WIDTH) && (H_TOTAL <= 2048))
            else $fatal(1, "H_TOTAL must be greater than ACTIVE_WIDTH and at most 2048");
        assert ((V_TOTAL > ACTIVE_HEIGHT) && (V_TOTAL <= 1024))
            else $fatal(1, "V_TOTAL must be greater than ACTIVE_HEIGHT and at most 1024");
    end

    assign bank_0_available = !bank_complete_q[0] && !(read_bank_active_q && !read_bank_q) && !(write_active_q && !write_bank_q);
    assign bank_1_available = !bank_complete_q[1] && !(read_bank_active_q && read_bank_q) && !(write_active_q && write_bank_q);

    assign empty_bank_valid = bank_0_available || bank_1_available;
    assign empty_bank_select = !bank_0_available;

    // While hunting, stale pixels are consumed without storage. A new SOF is
    // held only when no line bank is available to reserve it.
    always_comb begin
        if (pix_reset) begin
            s_axis_tready = 1'b0;
        end else if (write_active_q) begin
            s_axis_tready = 1'b1;
        end else if (source_hunting_q) begin
            if (s_axis_tvalid && s_axis_tuser) begin
                s_axis_tready = empty_bank_valid;
            end else begin
                s_axis_tready = 1'b1;
            end
        end else begin
            s_axis_tready = empty_bank_valid;
        end
    end

    assign input_transfer = s_axis_tvalid && s_axis_tready;

    // Select the memory write associated with the accepted transfer. An SOF
    // interrupting a partial line restarts that line in the reserved bank.
    always_comb begin
        input_store = 1'b0;
        input_store_bank = write_bank_q;
        input_store_address = write_column_q;

        if (input_transfer) begin
            if (write_active_q) begin
                input_store = 1'b1;

                if (s_axis_tuser) begin
                    input_store_address = '0;
                end
            end else if (!source_hunting_q || s_axis_tuser) begin
                input_store = empty_bank_valid;
                input_store_bank = empty_bank_select;
                input_store_address = '0;
            end
        end
    end

    assign input_bank_conflict = input_store && (bank_complete_q[input_store_bank] || (read_bank_active_q && (read_bank_q == input_store_bank)));

    assign raster_line_boundary = !pix_reset && (h_count == LAST_RASTER_X);
    assign next_raster_line = (v_count == LAST_RASTER_Y) ? 10'd0 : v_count + 1'b1;
    assign next_line_is_active = next_raster_line < ACTIVE_HEIGHT_VALUE;

    assign bank_0_line_match = bank_complete_q[0]
        && (bank_0_line_q == next_raster_line)
        && ((next_raster_line == 0) ? bank_sof_q[0] : !bank_sof_q[0]);
    assign bank_1_line_match = bank_complete_q[1]
        && (bank_1_line_q == next_raster_line)
        && ((next_raster_line == 0) ? bank_sof_q[1] : !bank_sof_q[1]);

    always_comb begin
        display_select_valid = 1'b0;
        display_select_bank = 1'b0;

        if (raster_line_boundary && next_line_is_active) begin
            if ((next_raster_line == 0) || frame_locked_q) begin
                if (bank_0_line_match) begin
                    display_select_valid = 1'b1;
                    display_select_bank = 1'b0;
                end else if (bank_1_line_match) begin
                    display_select_valid = 1'b1;
                    display_select_bank = 1'b1;
                end
            end
        end
    end

    // Block-RAM reads are issued one raster pixel ahead. At the end of a
    // raster line, address zero of the selected next line is prefetched.
    always_comb begin
        read_request_valid = 1'b0;
        read_request_bank = read_bank_q;
        read_request_address = '0;

        if (!pix_reset) begin
            if (raster_line_boundary && display_select_valid) begin
                read_request_valid = 1'b1;
                read_request_bank = display_select_bank;
                read_request_address = '0;
            end else if (read_bank_active_q
                && (v_count < ACTIVE_HEIGHT_VALUE)
                && (h_count < LAST_ACTIVE_X)) begin
                read_request_valid = 1'b1;
                read_request_bank = read_bank_q;
                read_request_address = h_count[ADDRESS_WIDTH-1:0] + 1'b1;
            end
        end
    end

    // The two memories are simple dual-port line stores: one synchronous write
    // port and one synchronous read port per bank. Ownership prevents a bank
    // from being displayed and filled at the same time.
    always_ff @(posedge pix_clk) begin
        if (input_store && !input_store_bank) begin
            line_bank_0[input_store_address] <= s_axis_tdata;
        end

        if (input_store && input_store_bank) begin
            line_bank_1[input_store_address] <= s_axis_tdata;
        end

        if (read_request_valid && !read_request_bank) begin
            bank_0_read_data_q <= line_bank_0[read_request_address];
        end

        if (read_request_valid && read_request_bank) begin
            bank_1_read_data_q <= line_bank_1[read_request_address];
        end
    end

    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            read_data_valid_q <= 1'b0;
            read_data_bank_q <= 1'b0;
        end else begin
            read_data_valid_q <= read_request_valid;
            read_data_bank_q <= read_request_bank;
        end
    end

    always_comb begin
        raster_rgb = 24'h000000;

        if (!pix_reset && active_video && frame_locked_q && read_data_valid_q) begin
            raster_rgb = read_data_bank_q ? bank_1_read_data_q : bank_0_read_data_q;
        end
    end

    assign status_frame_locked = frame_locked_q;
    assign status_overflow = status_overflow_q;
    assign status_malformed_line = status_malformed_line_q;
    assign status_underflow = status_underflow_q;
    assign status_black_fallback = status_black_fallback_q;

    always_comb begin
        bank_complete_n = bank_complete_q;
        bank_0_line_n = bank_0_line_q;
        bank_1_line_n = bank_1_line_q;
        bank_sof_n = bank_sof_q;

        write_active_n = write_active_q;
        write_bank_n = write_bank_q;
        write_column_n = write_column_q;
        write_line_n = write_line_q;
        write_sof_n = write_sof_q;

        source_hunting_n = source_hunting_q;
        source_line_n = source_line_q;

        read_bank_active_n = read_bank_active_q;
        read_bank_n = read_bank_q;
        frame_locked_n = frame_locked_q;
        lock_history_n = lock_history_q;

        status_overflow_n = status_overflow_q;
        status_malformed_line_n = status_malformed_line_q;
        status_underflow_n = status_underflow_q;
        status_black_fallback_n = status_black_fallback_q;

        if (input_bank_conflict) begin
            status_overflow_n = 1'b1;
        end

        if (input_transfer && input_store) begin
            if (write_active_q && !s_axis_tuser) begin
                if (s_axis_tlast != (write_column_q == LAST_WRITE_ADDRESS)) begin
                    status_malformed_line_n = 1'b1;
                end

                if (write_column_q == LAST_WRITE_ADDRESS) begin
                    bank_complete_n[write_bank_q] = 1'b1;

                    if (write_bank_q) begin
                        bank_1_line_n = write_line_q;
                    end else begin
                        bank_0_line_n = write_line_q;
                    end

                    bank_sof_n[write_bank_q] = write_sof_q;
                    write_active_n = 1'b0;
                    write_column_n = '0;

                    if (write_line_q == LAST_ACTIVE_Y) begin
                        source_hunting_n = 1'b1;
                        source_line_n = '0;
                    end else begin
                        source_hunting_n = 1'b0;
                        source_line_n = write_line_q + 1'b1;
                    end
                end else begin
                    write_column_n = write_column_q + 1'b1;
                end
            end else begin
                // This is either a normal SOF acquisition, the first pixel of
                // the expected next line, or an unexpected SOF restart.
                if (write_active_q || (!source_hunting_q && s_axis_tuser)) begin
                    status_malformed_line_n = 1'b1;
                end

                if (s_axis_tlast != (ACTIVE_WIDTH == 1)) begin
                    status_malformed_line_n = 1'b1;
                end

                write_bank_n = input_store_bank;
                write_line_n = s_axis_tuser ? 10'd0 : source_line_q;
                write_sof_n = s_axis_tuser;
                source_hunting_n = 1'b0;
                source_line_n = s_axis_tuser ? 10'd0 : source_line_q;

                if (ACTIVE_WIDTH == 1) begin
                    bank_complete_n[input_store_bank] = 1'b1;

                    if (input_store_bank) begin
                        bank_1_line_n = s_axis_tuser ? 10'd0 : source_line_q;
                    end else begin
                        bank_0_line_n = s_axis_tuser ? 10'd0 : source_line_q;
                    end

                    bank_sof_n[input_store_bank] = s_axis_tuser;
                    write_active_n = 1'b0;
                    write_column_n = '0;

                    if ((s_axis_tuser ? 10'd0 : source_line_q) == LAST_ACTIVE_Y) begin
                        source_hunting_n = 1'b1;
                        source_line_n = '0;
                    end else begin
                        source_line_n = (s_axis_tuser ? 10'd0 : source_line_q) + 1'b1;
                    end
                end else begin
                    write_active_n = 1'b1;
                    write_column_n = 'd1;
                end
            end
        end

        // The read bank remains reserved through the final active pixel.
        if (read_bank_active_q
            && (v_count < ACTIVE_HEIGHT_VALUE)
            && (h_count == LAST_ACTIVE_X)) begin
            read_bank_active_n = 1'b0;
        end

        if (raster_line_boundary) begin
            if (next_line_is_active && display_select_valid) begin
                bank_complete_n[display_select_bank] = 1'b0;
                read_bank_active_n = 1'b1;
                read_bank_n = display_select_bank;

                if (next_raster_line == 0) begin
                    frame_locked_n = 1'b1;
                    lock_history_n = 1'b1;
                end
            end else begin
                read_bank_active_n = 1'b0;

                if (next_raster_line == 0) begin
                    // A raster frame can start only with a completed SOF line.
                    // Startup black is expected; only loss after first lock is
                    // reported as underflow/fallback.
                    frame_locked_n = 1'b0;
                    bank_complete_n = '0;
                    write_active_n = 1'b0;
                    source_hunting_n = 1'b1;
                    source_line_n = '0;

                    if (lock_history_q) begin
                        status_underflow_n = 1'b1;
                        status_black_fallback_n = 1'b1;
                    end
                end else if (next_line_is_active && frame_locked_q) begin
                    // Do not substitute a late or differently tagged line.
                    // Black is held for the remainder of this raster frame.
                    frame_locked_n = 1'b0;
                    bank_complete_n = '0;
                    write_active_n = 1'b0;
                    source_hunting_n = 1'b1;
                    source_line_n = '0;
                    status_underflow_n = 1'b1;
                    status_black_fallback_n = 1'b1;
                end
            end
        end
    end

    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            bank_complete_q <= '0;
            bank_0_line_q <= '0;
            bank_1_line_q <= '0;
            bank_sof_q <= '0;

            write_active_q <= 1'b0;
            write_bank_q <= 1'b0;
            write_column_q <= '0;
            write_line_q <= '0;
            write_sof_q <= 1'b0;

            source_hunting_q <= 1'b1;
            source_line_q <= '0;

            read_bank_active_q <= 1'b0;
            read_bank_q <= 1'b0;
            frame_locked_q <= 1'b0;
            lock_history_q <= 1'b0;

            status_overflow_q <= 1'b0;
            status_malformed_line_q <= 1'b0;
            status_underflow_q <= 1'b0;
            status_black_fallback_q <= 1'b0;
        end else begin
            bank_complete_q <= bank_complete_n;
            bank_0_line_q <= bank_0_line_n;
            bank_1_line_q <= bank_1_line_n;
            bank_sof_q <= bank_sof_n;

            write_active_q <= write_active_n;
            write_bank_q <= write_bank_n;
            write_column_q <= write_column_n;
            write_line_q <= write_line_n;
            write_sof_q <= write_sof_n;

            source_hunting_q <= source_hunting_n;
            source_line_q <= source_line_n;

            read_bank_active_q <= read_bank_active_n;
            read_bank_q <= read_bank_n;
            frame_locked_q <= frame_locked_n;
            lock_history_q <= lock_history_n;

            status_overflow_q <= status_overflow_n;
            status_malformed_line_q <= status_malformed_line_n;
            status_underflow_q <= status_underflow_n;
            status_black_fallback_q <= status_black_fallback_n;
        end
    end

endmodule
