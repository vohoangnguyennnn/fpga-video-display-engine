// Stall-aware transactional join and frame-coherent video mode selection.
//
// One aligned payload and one Sobel result are consumed together. The selected
// RGB888 result is registered so payload and markers remain stable under output
// backpressure. active_mode is supplied by the top-level configuration commit.

module video_mode_mux
    import video_pkg::video_payload_t;
(
    input logic aclk,
    input logic aresetn,

    input video_payload_t s_aligned_payload,
    input logic s_aligned_valid,
    output logic s_aligned_ready,

    input logic [7:0] s_sobel_magnitude,
    input logic [7:0] s_sobel_edge,
    input logic s_sobel_valid,
    output logic s_sobel_ready,

    input logic [1:0] active_mode,

    output video_payload_t m_axis_payload,
    output logic m_axis_tvalid,
    input logic m_axis_tready
);

    localparam logic [1:0] MODE_PASSTHROUGH = 2'd0;
    localparam logic [1:0] MODE_GRAYSCALE = 2'd1;
    localparam logic [1:0] MODE_SOBEL_MAGNITUDE = 2'd2;
    localparam logic [1:0] MODE_BINARY_EDGE = 2'd3;

    logic [1:0] frame_mode_q;
    logic [1:0] selected_mode;

    video_payload_t selected_payload;
    video_payload_t output_payload_q;
    logic output_valid_q;

    logic output_slot_ready;
    logic joined_valid;

    assign output_slot_ready = !output_valid_q || m_axis_tready;
    assign joined_valid = s_aligned_valid && s_sobel_valid;

    // Neither branch may advance without its matching token.
    assign s_aligned_ready = output_slot_ready && s_sobel_valid;
    assign s_sobel_ready = output_slot_ready && s_aligned_valid;

    assign m_axis_payload = output_payload_q;
    assign m_axis_tvalid = output_valid_q;

    // The top level commits active_mode at the accepted input SOF. Capturing it
    // again on the delayed aligned SOF makes the selection explicitly constant
    // throughout the corresponding output frame.
    assign selected_mode = s_aligned_payload.sof ? active_mode : frame_mode_q;

    always_comb begin
        selected_payload = s_aligned_payload;

        case (selected_mode)
            MODE_PASSTHROUGH: begin
                selected_payload.rgb = s_aligned_payload.rgb;
            end

            MODE_GRAYSCALE: begin
                selected_payload.rgb = {3{s_aligned_payload.gray}};
            end

            MODE_SOBEL_MAGNITUDE: begin
                if (s_aligned_payload.border) begin
                    selected_payload.rgb = 24'd0;
                end else begin
                    selected_payload.rgb = {3{s_sobel_magnitude}};
                end
            end

            MODE_BINARY_EDGE: begin
                if (s_aligned_payload.border) begin
                    selected_payload.rgb = 24'd0;
                end else begin
                    selected_payload.rgb = {3{s_sobel_edge}};
                end
            end

            default: begin
                selected_payload.rgb = s_aligned_payload.rgb;
            end
        endcase
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            frame_mode_q <= MODE_PASSTHROUGH;
            output_valid_q <= 1'b0;
        end else if (output_slot_ready) begin
            output_valid_q <= joined_valid;

            if (joined_valid) begin
                output_payload_q <= selected_payload;

                if (s_aligned_payload.sof) begin
                    frame_mode_q <= active_mode;
                end
            end
        end
    end

endmodule
