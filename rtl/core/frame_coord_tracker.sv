// AXI4-Stream Video ingress coordinate and framing tracker.
//
// Legal frame tokens are enriched with the canonical internal metadata before
// entering the input elastic buffer. Malformed tokens outside a legal frame are
// consumed and reported, but are not forwarded.

import video_pkg::video_payload_t;

module frame_coord_tracker #(
    parameter integer MAX_WIDTH = 1280,
    parameter integer MAX_HEIGHT = 720
) (
    input logic aclk,
    input logic aresetn,

    input logic [23:0] s_axis_tdata,
    input logic s_axis_tvalid,
    output logic s_axis_tready,
    input logic s_axis_tuser,
    input logic s_axis_tlast,

    input logic [15:0] cfg_frame_width,
    input logic [15:0] cfg_frame_height,

    output video_payload_t m_axis_payload,
    output logic m_axis_tvalid,
    input logic m_axis_tready,

    output logic [15:0] active_width,
    output logic [15:0] active_height,
    // Ingress parsing state only; top-level status_in_frame also covers drain.
    output logic tracker_in_frame,
    output logic status_protocol_error
);

    localparam logic [15:0] MAX_WIDTH_VALUE = MAX_WIDTH[15:0];
    localparam logic [15:0] MAX_HEIGHT_VALUE = MAX_HEIGHT[15:0];

    logic [15:0] x_q;
    logic [15:0] y_q;
    logic [15:0] active_width_q;
    logic [15:0] active_height_q;
    logic frame_active_q;

    logic cfg_dimensions_valid;
    logic forward_token;
    logic [15:0] token_x;
    logic [15:0] token_y;
    logic [15:0] token_width;
    logic [15:0] token_height;
    logic token_eof;
    logic token_border;
    logic input_accepted;

    initial begin
        assert ((MAX_WIDTH >= 3) && (MAX_WIDTH <= 65535))
            else $fatal(1, "MAX_WIDTH must be in the range 3..65535");
        assert ((MAX_HEIGHT >= 1) && (MAX_HEIGHT <= 65535))
            else $fatal(1, "MAX_HEIGHT must be in the range 1..65535");
    end

    assign cfg_dimensions_valid = (cfg_frame_width != 16'd0) && (cfg_frame_height != 16'd0) && (cfg_frame_width <= MAX_WIDTH_VALUE) && (cfg_frame_height <= MAX_HEIGHT_VALUE);

    always_comb begin
        forward_token = frame_active_q;
        token_x = x_q;
        token_y = y_q;
        token_width = active_width_q;
        token_height = active_height_q;

        if (s_axis_tuser) begin
            forward_token = cfg_dimensions_valid;
            token_x = 16'd0;
            token_y = 16'd0;
            token_width = cfg_frame_width;
            token_height = cfg_frame_height;
        end

        token_eof = forward_token && (token_x == (token_width - 16'd1)) && (token_y == (token_height - 16'd1));

        token_border = forward_token && ((token_x == 16'd0) || (token_y == 16'd0) || (token_x == (token_width - 16'd1)) || (token_y == (token_height - 16'd1)));

        m_axis_payload.rgb = s_axis_tdata;
        m_axis_payload.gray = 8'd0;
        m_axis_payload.sof = s_axis_tuser;
        m_axis_payload.eol = s_axis_tlast;
        m_axis_payload.eof = token_eof;
        m_axis_payload.border = token_border;
    end

    assign m_axis_tvalid = aresetn && s_axis_tvalid && forward_token;
    assign s_axis_tready = aresetn && (forward_token ? m_axis_tready : 1'b1);
    assign input_accepted = s_axis_tvalid && s_axis_tready;

    assign active_width = active_width_q;
    assign active_height = active_height_q;
    assign tracker_in_frame = frame_active_q;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            x_q <= 16'd0;
            y_q <= 16'd0;
            active_width_q <= 16'd0;
            active_height_q <= 16'd0;
            frame_active_q <= 1'b0;
            status_protocol_error <= 1'b0;
        end else if (input_accepted) begin
            if (s_axis_tuser) begin
                if (frame_active_q || !cfg_dimensions_valid) begin
                    status_protocol_error <= 1'b1;
                end

                if (cfg_dimensions_valid) begin
                    active_width_q <= cfg_frame_width;
                    active_height_q <= cfg_frame_height;

                    if (s_axis_tlast != (cfg_frame_width == 16'd1)) begin
                        status_protocol_error <= 1'b1;
                    end

                    if ((cfg_frame_width == 16'd1) && (cfg_frame_height == 16'd1)) begin
                        x_q <= 16'd0;
                        y_q <= 16'd0;
                        frame_active_q <= 1'b0;
                    end else if (cfg_frame_width == 16'd1) begin
                        x_q <= 16'd0;
                        y_q <= 16'd1;
                        frame_active_q <= 1'b1;
                    end else begin
                        x_q <= 16'd1;
                        y_q <= 16'd0;
                        frame_active_q <= 1'b1;
                    end
                end else begin
                    x_q <= 16'd0;
                    y_q <= 16'd0;
                    frame_active_q <= 1'b0;
                end
            end else if (!frame_active_q) begin
                status_protocol_error <= 1'b1;
            end else begin
                if (s_axis_tlast != (x_q == (active_width_q - 16'd1))) begin
                    status_protocol_error <= 1'b1;
                end

                if ((x_q == (active_width_q - 16'd1)) && (y_q == (active_height_q - 16'd1))) begin
                    x_q <= 16'd0;
                    y_q <= 16'd0;
                    frame_active_q <= 1'b0;
                end else if (x_q == (active_width_q - 16'd1)) begin
                    x_q <= 16'd0;
                    y_q <= y_q + 16'd1;
                end else begin
                    x_q <= x_q + 16'd1;
                end
            end
        end
    end

endmodule
