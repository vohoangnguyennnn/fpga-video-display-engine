// Vendor-neutral, single-pixel-per-clock RGB/Sobel AXI4-Stream core.
//
// This module owns configuration commit, legal-frame serialization, pipeline
// integration, malformed-frame recovery, and the external status signals.

module video_stream_core
    import video_pkg::video_payload_t;
#(
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

    output logic [23:0] m_axis_tdata,
    output logic m_axis_tvalid,
    input logic m_axis_tready,
    output logic m_axis_tuser,
    output logic m_axis_tlast,

    input logic [1:0] cfg_mode,
    input logic [7:0] cfg_threshold,
    input logic [15:0] cfg_frame_width,
    input logic [15:0] cfg_frame_height,

    output logic status_in_frame,
    output logic status_protocol_error
);

    localparam logic [15:0] MAX_WIDTH_VALUE = MAX_WIDTH[15:0];
    localparam logic [15:0] MAX_HEIGHT_VALUE = MAX_HEIGHT[15:0];

    logic [1:0] active_mode_q;
    logic [7:0] active_threshold_q;
    logic frame_in_flight_q;
    logic protocol_error_q;
    logic recovery_pending_q;

    logic cfg_dimensions_valid;
    logic input_path_open;
    logic recovery_request;
    logic output_safe_to_flush;
    logic pipeline_flush;
    logic pipeline_aresetn;
    logic input_transfer;
    logic legal_sof_transfer;
    logic output_transfer;
    logic output_eof_transfer;

    video_payload_t tracker_payload;
    logic tracker_valid;
    logic tracker_ready;
    logic tracker_input_valid;
    logic [15:0] active_width;
    logic [15:0] active_height;
    logic tracker_in_frame;
    logic tracker_protocol_error;

    video_payload_t input_buffer_payload;
    logic input_buffer_valid;
    logic input_buffer_ready;
    logic input_buffer_ready_from_gray;

    video_payload_t grayscale_payload;
    logic grayscale_valid;
    logic grayscale_ready;

    logic window_input_valid;
    logic window_input_ready;
    logic align_input_valid;
    logic align_input_ready;

    logic [7:0] window_p00;
    logic [7:0] window_p01;
    logic [7:0] window_p02;
    logic [7:0] window_p10;
    logic [7:0] window_p11;
    logic [7:0] window_p12;
    logic [7:0] window_p20;
    logic [7:0] window_p21;
    logic [7:0] window_p22;
    logic window_valid;
    logic window_ready;

    logic signed [11:0] gradient_gx;
    logic signed [11:0] gradient_gy;
    logic gradient_valid;
    logic gradient_ready;

    logic [7:0] sobel_magnitude;
    logic [7:0] sobel_edge;
    logic sobel_valid;
    logic sobel_ready;

    video_payload_t aligned_payload;
    logic aligned_valid;
    logic aligned_ready;

    video_payload_t selected_payload;
    logic selected_valid;
    logic selected_ready;

    video_payload_t output_buffer_payload;
    logic output_buffer_valid;
    logic _unused_output_payload_fields;

    logic window_branch_transfer;
    logic align_branch_transfer;
    logic aligned_join_transfer;
    logic sobel_join_transfer;

    initial begin
        assert ((MAX_WIDTH >= 3) && (MAX_WIDTH <= 65535))
            else $fatal(1, "MAX_WIDTH must be in the range 3..65535");
        assert ((MAX_HEIGHT >= 1) && (MAX_HEIGHT <= 65535))
            else $fatal(1, "MAX_HEIGHT must be in the range 1..65535");
    end

    assign cfg_dimensions_valid = (cfg_frame_width != 16'd0) && (cfg_frame_height != 16'd0) && (cfg_frame_width <= MAX_WIDTH_VALUE) && (cfg_frame_height <= MAX_HEIGHT_VALUE);

    // A frame may accept pixels through its configured final input transfer.
    // The next frame remains blocked until the prior output EOF is accepted.
    assign input_path_open = !frame_in_flight_q || tracker_in_frame;

    // An SOF before the configured final input pixel restarts the pipeline. The
    // source holds that SOF while recovery preserves any already-stalled output.
    assign recovery_request = aresetn && frame_in_flight_q && tracker_in_frame && s_axis_tvalid && s_axis_tuser;
    assign output_safe_to_flush = !m_axis_tvalid || m_axis_tready;
    assign pipeline_flush = aresetn && (recovery_pending_q || recovery_request) && output_safe_to_flush;
    assign pipeline_aresetn = aresetn && !pipeline_flush;

    assign tracker_input_valid = s_axis_tvalid && input_path_open && !recovery_pending_q && !recovery_request;
    assign s_axis_tready = pipeline_aresetn && input_path_open && !recovery_pending_q && !recovery_request && tracker_ready;

    assign input_transfer = s_axis_tvalid && s_axis_tready;
    assign legal_sof_transfer = input_transfer && s_axis_tuser && cfg_dimensions_valid;

    assign m_axis_tdata = output_buffer_payload.rgb;
    assign m_axis_tvalid = output_buffer_valid;
    assign m_axis_tuser = output_buffer_payload.sof;
    assign m_axis_tlast = output_buffer_payload.eol;

    assign output_transfer = m_axis_tvalid && m_axis_tready;
    assign output_eof_transfer = output_transfer && output_buffer_payload.eof;
    assign _unused_output_payload_fields = &{1'b0, output_buffer_payload.gray, output_buffer_payload.border};

    assign status_in_frame = frame_in_flight_q;
    assign status_protocol_error = protocol_error_q || tracker_protocol_error;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            active_mode_q <= 2'd0;
            active_threshold_q <= 8'd0;
            frame_in_flight_q <= 1'b0;
            protocol_error_q <= 1'b0;
            recovery_pending_q <= 1'b0;
        end else begin
            protocol_error_q <= protocol_error_q || tracker_protocol_error || recovery_request;

            if (pipeline_flush) begin
                active_mode_q <= 2'd0;
                active_threshold_q <= 8'd0;
                frame_in_flight_q <= 1'b0;
                recovery_pending_q <= 1'b0;
            end else begin
                if (recovery_request) begin
                    recovery_pending_q <= 1'b1;
                end

                if (legal_sof_transfer) begin
                    active_mode_q <= cfg_mode;
                    active_threshold_q <= cfg_threshold;
                    frame_in_flight_q <= 1'b1;
                end else if (output_eof_transfer) begin
                    frame_in_flight_q <= 1'b0;
                end
            end
        end
    end

    frame_coord_tracker #(
        .MAX_WIDTH(MAX_WIDTH),
        .MAX_HEIGHT(MAX_HEIGHT)
    ) frame_coord_tracker_inst (
        .aclk,
        .aresetn(pipeline_aresetn),
        .s_axis_tdata,
        .s_axis_tvalid(tracker_input_valid),
        .s_axis_tready(tracker_ready),
        .s_axis_tuser,
        .s_axis_tlast,
        .cfg_frame_width,
        .cfg_frame_height,
        .m_axis_payload(tracker_payload),
        .m_axis_tvalid(tracker_valid),
        .m_axis_tready(input_buffer_ready),
        .active_width,
        .active_height,
        .tracker_in_frame,
        .status_protocol_error(tracker_protocol_error)
    );

    axis_elastic_buffer input_buffer_inst (
        .aclk,
        .aresetn(pipeline_aresetn),
        .s_axis_payload(tracker_payload),
        .s_axis_tvalid(tracker_valid),
        .s_axis_tready(input_buffer_ready),
        .m_axis_payload(input_buffer_payload),
        .m_axis_tvalid(input_buffer_valid),
        .m_axis_tready(input_buffer_ready_from_gray)
    );

    rgb_to_gray rgb_to_gray_inst (
        .aclk,
        .aresetn(pipeline_aresetn),
        .s_axis_payload(input_buffer_payload),
        .s_axis_tvalid(input_buffer_valid),
        .s_axis_tready(input_buffer_ready_from_gray),
        .m_axis_payload(grayscale_payload),
        .m_axis_tvalid(grayscale_valid),
        .m_axis_tready(grayscale_ready)
    );

    // Transactional fork: both consumers accept the same grayscale token on
    // the same clock, or neither branch advances.
    assign grayscale_ready = window_input_ready && align_input_ready;
    assign window_input_valid = grayscale_valid && align_input_ready;
    assign align_input_valid = grayscale_valid && window_input_ready;

    window_3x3 #(
        .MAX_WIDTH(MAX_WIDTH),
        .MAX_HEIGHT(MAX_HEIGHT)
    ) window_3x3_inst (
        .aclk,
        .aresetn(pipeline_aresetn),
        .s_axis_payload(grayscale_payload),
        .s_axis_tvalid(window_input_valid),
        .s_axis_tready(window_input_ready),
        .active_width,
        .active_height,
        .m_window_p00(window_p00),
        .m_window_p01(window_p01),
        .m_window_p02(window_p02),
        .m_window_p10(window_p10),
        .m_window_p11(window_p11),
        .m_window_p12(window_p12),
        .m_window_p20(window_p20),
        .m_window_p21(window_p21),
        .m_window_p22(window_p22),
        .m_window_valid(window_valid),
        .m_window_ready(window_ready)
    );

    stream_align_delay #(
        .MAX_WIDTH(MAX_WIDTH)
    ) stream_align_delay_inst (
        .aclk,
        .aresetn(pipeline_aresetn),
        .s_axis_payload(grayscale_payload),
        .s_axis_tvalid(align_input_valid),
        .s_axis_tready(align_input_ready),
        .m_axis_payload(aligned_payload),
        .m_axis_tvalid(aligned_valid),
        .m_axis_tready(aligned_ready)
    );

    sobel_gx_gy sobel_gx_gy_inst (
        .aclk,
        .aresetn(pipeline_aresetn),
        .s_window_p00(window_p00),
        .s_window_p01(window_p01),
        .s_window_p02(window_p02),
        .s_window_p10(window_p10),
        .s_window_p11(window_p11),
        .s_window_p12(window_p12),
        .s_window_p20(window_p20),
        .s_window_p21(window_p21),
        .s_window_p22(window_p22),
        .s_window_valid(window_valid),
        .s_window_ready(window_ready),
        .m_gradient_gx(gradient_gx),
        .m_gradient_gy(gradient_gy),
        .m_gradient_valid(gradient_valid),
        .m_gradient_ready(gradient_ready)
    );

    sobel_magnitude sobel_magnitude_inst (
        .aclk,
        .aresetn(pipeline_aresetn),
        .s_gradient_gx(gradient_gx),
        .s_gradient_gy(gradient_gy),
        .s_gradient_valid(gradient_valid),
        .s_gradient_ready(gradient_ready),
        .active_threshold(active_threshold_q),
        .m_sobel_magnitude(sobel_magnitude),
        .m_sobel_edge(sobel_edge),
        .m_sobel_valid(sobel_valid),
        .m_sobel_ready(sobel_ready)
    );

    video_mode_mux video_mode_mux_inst (
        .aclk,
        .aresetn(pipeline_aresetn),
        .s_aligned_payload(aligned_payload),
        .s_aligned_valid(aligned_valid),
        .s_aligned_ready(aligned_ready),
        .s_sobel_magnitude(sobel_magnitude),
        .s_sobel_edge(sobel_edge),
        .s_sobel_valid(sobel_valid),
        .s_sobel_ready(sobel_ready),
        .active_mode(active_mode_q),
        .m_axis_payload(selected_payload),
        .m_axis_tvalid(selected_valid),
        .m_axis_tready(selected_ready)
    );

    axis_elastic_buffer output_buffer_inst (
        .aclk,
        .aresetn(pipeline_aresetn),
        .s_axis_payload(selected_payload),
        .s_axis_tvalid(selected_valid),
        .s_axis_tready(selected_ready),
        .m_axis_payload(output_buffer_payload),
        .m_axis_tvalid(output_buffer_valid),
        .m_axis_tready
    );

    assign window_branch_transfer = window_input_valid && window_input_ready;
    assign align_branch_transfer = align_input_valid && align_input_ready;
    assign aligned_join_transfer = aligned_valid && aligned_ready;
    assign sobel_join_transfer = sobel_valid && sobel_ready;

`ifndef SYNTHESIS
    always_ff @(posedge aclk) begin
        if (pipeline_aresetn) begin
            assert (window_branch_transfer == align_branch_transfer)
                else $error("grayscale fork branches advanced independently");
            assert (aligned_join_transfer == sobel_join_transfer)
                else $error("mode-mux join branches advanced independently");
        end
    end
`endif

endmodule
