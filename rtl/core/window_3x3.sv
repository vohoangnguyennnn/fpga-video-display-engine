// Stall-aware centered 3x3 grayscale window generator.
//
// Two read-first line stores retain the prior two rows. A synchronous RAM-read
// stage feeds three horizontal shift-register rows. Output windows use a fixed
// accepted-token look-ahead of active_width+1; border tokens are represented by
// all-zero windows, and the bottom row is emitted by an internal drain.

import video_pkg::video_payload_t;

module window_3x3 #(
    parameter integer MAX_WIDTH = 1280,
    parameter integer MAX_HEIGHT = 720
) (
    input logic aclk,
    input logic aresetn,

    input video_payload_t s_axis_payload,
    input logic s_axis_tvalid,
    output logic s_axis_tready,

    input logic [15:0] active_width,
    input logic [15:0] active_height,

    output logic [7:0] m_window_p00,
    output logic [7:0] m_window_p01,
    output logic [7:0] m_window_p02,
    output logic [7:0] m_window_p10,
    output logic [7:0] m_window_p11,
    output logic [7:0] m_window_p12,
    output logic [7:0] m_window_p20,
    output logic [7:0] m_window_p21,
    output logic [7:0] m_window_p22,
    output logic m_window_valid,
    input logic m_window_ready
);

    logic [7:0] line_store0 [0:MAX_WIDTH-1];
    logic [7:0] line_store1 [0:MAX_WIDTH-1];

    localparam integer ADDRESS_WIDTH = $clog2(MAX_WIDTH);

    logic [7:0] line0_read_q;
    logic [7:0] line1_read_q;

    logic [15:0] x_q;
    logic [15:0] y_q;
    logic [15:0] frame_width_q;
    logic [15:0] frame_height_q;
    logic write_bank_q;
    logic input_done_q;

    logic read_valid_q;
    logic [15:0] read_x_q;
    logic [15:0] read_y_q;
    logic [15:0] read_width_q;
    logic [15:0] read_height_q;
    logic [7:0] read_gray_q;
    logic read_write_bank_q;
    logic read_output_due_q;
    logic read_real_window_q;
    logic read_final_q;

    logic [7:0] row0_previous2_q;
    logic [7:0] row0_previous1_q;
    logic [7:0] row1_previous2_q;
    logic [7:0] row1_previous1_q;
    logic [7:0] row2_previous2_q;
    logic [7:0] row2_previous1_q;

    logic [71:0] window_q;
    logic window_valid_q;
    logic draining_q;
    logic [16:0] drain_remaining_q;

    logic [15:0] accepted_x;
    logic [15:0] accepted_y;
    logic [15:0] accepted_width;
    logic [15:0] accepted_height;
    logic [ADDRESS_WIDTH-1:0] accepted_address;
    logic accepted_write_bank;
    logic accepted_output_due;
    logic accepted_real_window;
    logic accepted_final;

    logic [7:0] pending_oldest_pixel;
    logic [7:0] pending_previous_pixel;
    logic [71:0] pending_window;

    logic output_slot_ready;
    logic read_stage_ready;
    logic process_pending;
    logic accept_input;
    logic _unused_payload_fields;

    initial begin
        assert ((MAX_WIDTH >= 3) && (MAX_WIDTH <= 65535))
            else $fatal(1, "MAX_WIDTH must be in the range 3..65535");
        assert ((MAX_HEIGHT >= 1) && (MAX_HEIGHT <= 65535))
            else $fatal(1, "MAX_HEIGHT must be in the range 1..65535");
    end

    assign {
        m_window_p00,
        m_window_p01,
        m_window_p02,
        m_window_p10,
        m_window_p11,
        m_window_p12,
        m_window_p20,
        m_window_p21,
        m_window_p22
    } = window_q;
    assign m_window_valid = window_valid_q;

    assign output_slot_ready = !window_valid_q || m_window_ready;
    assign read_stage_ready =!read_valid_q || !read_output_due_q || output_slot_ready;
    assign process_pending = read_valid_q && read_stage_ready;
    assign accepted_address = accepted_x[ADDRESS_WIDTH-1:0];

    // RGB and downstream-only metadata travel on the parallel alignment path.
    assign _unused_payload_fields = &{1'b0, s_axis_payload.rgb, s_axis_payload.eol, s_axis_payload.border};

    // input_done_q covers the synchronous RAM-read stage between the accepted
    // final pixel and entry into the explicit border-drain state.
    assign s_axis_tready = !input_done_q && !draining_q && read_stage_ready;
    assign accept_input = s_axis_tvalid && s_axis_tready;

    always_comb begin
        accepted_x = x_q;
        accepted_y = y_q;
        accepted_width = frame_width_q;
        accepted_height = frame_height_q;
        accepted_write_bank = write_bank_q;

        if (s_axis_payload.sof) begin
            accepted_x = 16'd0;
            accepted_y = 16'd0;
            accepted_width = active_width;
            accepted_height = active_height;
            accepted_write_bank = 1'b0;
        end

        accepted_output_due = (accepted_y > 16'd1) || ((accepted_y == 16'd1) && (accepted_x >= 16'd1));
        accepted_real_window = accepted_output_due && (accepted_width >= 16'd3) && (accepted_height >= 16'd3) && (accepted_x >= 16'd2) && (accepted_y >= 16'd2);
        accepted_final = s_axis_payload.eof;
    end

    always_comb begin
        pending_oldest_pixel = 8'd0;
        pending_previous_pixel = 8'd0;

        if (read_y_q >= 16'd2) begin
            pending_oldest_pixel = read_write_bank_q ? line1_read_q : line0_read_q;
        end
        if (read_y_q >= 16'd1) begin
            pending_previous_pixel =  read_write_bank_q ? line0_read_q : line1_read_q;
        end

        pending_window = {
            row0_previous2_q,
            row0_previous1_q,
            pending_oldest_pixel,
            row1_previous2_q,
            row1_previous1_q,
            pending_previous_pixel,
            row2_previous2_q,
            row2_previous1_q,
            read_gray_q
        };
    end

    // Separate synchronous read and write processes form a simple-dual-port
    // inference template. Both ports use the same address for this algorithm.
    // Nonblocking assignment semantics make a collision return the old pixel
    // in simulation; synthesis must preserve that READ_FIRST behavior.
    always_ff @(posedge aclk) begin
        if (accept_input) begin
            line0_read_q <= line_store0[accepted_address];
        end
    end

    always_ff @(posedge aclk) begin
        if (accept_input) begin
            line1_read_q <= line_store1[accepted_address];
        end
    end

    always_ff @(posedge aclk) begin
        if (accept_input && !accepted_write_bank) begin
            line_store0[accepted_address] <= s_axis_payload.gray;
        end
    end

    always_ff @(posedge aclk) begin
        if (accept_input && accepted_write_bank) begin
            line_store1[accepted_address] <= s_axis_payload.gray;
        end
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            x_q <= 16'd0;
            y_q <= 16'd0;
            frame_width_q <= 16'd0;
            frame_height_q <= 16'd0;
            write_bank_q <= 1'b0;
            input_done_q <= 1'b0;

            read_valid_q <= 1'b0;

            window_valid_q <= 1'b0;
            draining_q <= 1'b0;
            drain_remaining_q <= 17'd0;
        end else begin
            if (read_stage_ready) begin
                read_valid_q <= accept_input;
                if (accept_input) begin
                    read_x_q <= accepted_x;
                    read_y_q <= accepted_y;
                    read_width_q <= accepted_width;
                    read_height_q <= accepted_height;
                    read_gray_q <= s_axis_payload.gray;
                    read_write_bank_q <= accepted_write_bank;
                    read_output_due_q <= accepted_output_due;
                    read_real_window_q <= accepted_real_window;
                    read_final_q <= accepted_final;
                end
            end

            if (accept_input) begin
                if (s_axis_payload.sof) begin
                    frame_width_q <= active_width;
                    frame_height_q <= active_height;
                end

                if (accepted_final) begin
                    x_q <= 16'd0;
                    y_q <= 16'd0;
                    write_bank_q <= 1'b0;
                    input_done_q <= 1'b1;
                end else if (accepted_x == (accepted_width - 16'd1)) begin
                    x_q <= 16'd0;
                    y_q <= accepted_y + 16'd1;
                    write_bank_q <= !accepted_write_bank;
                end else begin
                    x_q <= accepted_x + 16'd1;
                    y_q <= accepted_y;
                    write_bank_q <= accepted_write_bank;
                end
            end

            if (process_pending) begin
                if (read_x_q == 16'd0) begin
                    row0_previous2_q <= 8'd0;
                    row0_previous1_q <= pending_oldest_pixel;
                    row1_previous2_q <= 8'd0;
                    row1_previous1_q <= pending_previous_pixel;
                    row2_previous2_q <= 8'd0;
                    row2_previous1_q <= read_gray_q;
                end else begin
                    row0_previous2_q <= row0_previous1_q;
                    row0_previous1_q <= pending_oldest_pixel;
                    row1_previous2_q <= row1_previous1_q;
                    row1_previous1_q <= pending_previous_pixel;
                    row2_previous2_q <= row2_previous1_q;
                    row2_previous1_q <= read_gray_q;
                end
            end

            if (draining_q) begin
                if (output_slot_ready) begin
                    if (drain_remaining_q != 17'd0) begin
                        window_q <= 72'd0;
                        window_valid_q <= 1'b1;
                        drain_remaining_q <= drain_remaining_q - 17'd1;
                    end else begin
                        window_valid_q <= 1'b0;
                        draining_q <= 1'b0;
                        input_done_q <= 1'b0;
                        x_q <= 16'd0;
                        y_q <= 16'd0;
                        write_bank_q <= 1'b0;
                    end
                end
            end else begin
                if (window_valid_q && m_window_ready) begin
                    window_valid_q <= 1'b0;
                end

                if (process_pending && read_output_due_q) begin
                    window_q <= read_real_window_q ? pending_window : 72'd0;
                    window_valid_q <= 1'b1;
                end

                if (process_pending && read_final_q) begin
                    draining_q <= 1'b1;
                    if (read_height_q == 16'd1) begin
                        drain_remaining_q <= {1'b0, read_width_q};
                    end else begin
                        drain_remaining_q <= {1'b0, read_width_q} + 17'd1;
                    end
                end
            end
        end
    end

endmodule
