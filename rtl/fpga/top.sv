// MicroPhase A7-LITE R1.1 720p DVI-over-HDMI demonstration top.
//
// Physical user I/O follows the reviewed board schematic:
//   K1 -> key_mode_n
//   K2 -> key_threshold_up_n
//   K3 (schematic net RESET) -> key_threshold_down_n
// All three keys and both user LEDs are active low. K3 is intentionally used
// as a configuration key; startup and clock-loss reset comes from MMCM LOCKED
// and the per-domain reset conditioners in video_clock_reset.
//
// HDMI lane mapping follows the DVI convention:
//   data[0] = blue + {VSYNC, HSYNC} control
//   data[1] = green
//   data[2] = red

module top #(
    parameter integer BUTTON_DEBOUNCE_CYCLES = 1_484_375
) (
    input logic clk_50m,

    input logic key_mode_n,
    input logic key_threshold_up_n,
    input logic key_threshold_down_n,

    output logic [2:0] hdmi_data_p,
    output logic [2:0] hdmi_data_n,
    output logic hdmi_clk_p,
    output logic hdmi_clk_n,

    output logic led_frame_locked_n,
    output logic led_fault_n
);

    localparam logic [15:0] FRAME_WIDTH = 16'd1280;
    localparam logic [15:0] FRAME_HEIGHT = 16'd720;
    localparam logic [9:0] TMDS_CLOCK_WORD = 10'b1111100000;

    logic pix_clk;
    logic tmds_clk_5x;
    logic pix_reset;
    logic tmds_reset;
    logic core_aresetn;

    logic [1:0] cfg_mode;
    logic [7:0] cfg_threshold;

    logic [23:0] pattern_tdata;
    logic pattern_tvalid;
    logic pattern_tready;
    logic pattern_tuser;
    logic pattern_tlast;

    logic [23:0] core_tdata;
    logic core_tvalid;
    logic core_tready;
    logic core_tuser;
    logic core_tlast;
    logic _unused_core_status_in_frame;
    logic core_status_protocol_error;

    logic [10:0] h_count;
    logic [9:0] v_count;
    logic active_video;
    logic hsync;
    logic vsync;

    logic [23:0] raster_rgb;
    logic raster_status_frame_locked;
    logic raster_status_overflow;
    logic raster_status_malformed_line;
    logic raster_status_underflow;
    logic raster_status_black_fallback;
    logic status_fault;

    logic [9:0] tmds_blue;
    logic [9:0] tmds_green;
    logic [9:0] tmds_red;

    assign core_aresetn = !pix_reset;

    assign status_fault = core_status_protocol_error || raster_status_overflow || raster_status_malformed_line || raster_status_underflow || raster_status_black_fallback;

    // The R1.1 LED anodes are tied to 3.3 V, so driving the FPGA pin low
    // illuminates the corresponding LED.
    assign led_frame_locked_n = !raster_status_frame_locked;
    assign led_fault_n = !status_fault;

    video_clock_reset u_video_clock_reset (
        .clk_50m,
        .reset_async(1'b0),
        .pix_clk,
        .tmds_clk_5x,
        .pix_reset,
        .tmds_reset
    );

    button_control #(
        .DEBOUNCE_CYCLES(BUTTON_DEBOUNCE_CYCLES)
    ) u_button_control (
        .pix_clk,
        .pix_reset,
        .btn_mode(!key_mode_n),
        .btn_threshold_up(!key_threshold_up_n),
        .btn_threshold_down(!key_threshold_down_n),
        .cfg_mode,
        .cfg_threshold
    );

    video_test_pattern u_video_test_pattern (
        .pix_clk,
        .pix_reset,
        .m_axis_tdata(pattern_tdata),
        .m_axis_tvalid(pattern_tvalid),
        .m_axis_tready(pattern_tready),
        .m_axis_tuser(pattern_tuser),
        .m_axis_tlast(pattern_tlast)
    );

    video_stream_core #(
        .MAX_WIDTH(1280),
        .MAX_HEIGHT(720)
    ) u_video_stream_core (
        .aclk(pix_clk),
        .aresetn(core_aresetn),

        .s_axis_tdata(pattern_tdata),
        .s_axis_tvalid(pattern_tvalid),
        .s_axis_tready(pattern_tready),
        .s_axis_tuser(pattern_tuser),
        .s_axis_tlast(pattern_tlast),

        .m_axis_tdata(core_tdata),
        .m_axis_tvalid(core_tvalid),
        .m_axis_tready(core_tready),
        .m_axis_tuser(core_tuser),
        .m_axis_tlast(core_tlast),

        .cfg_mode,
        .cfg_threshold,
        .cfg_frame_width(FRAME_WIDTH),
        .cfg_frame_height(FRAME_HEIGHT),

        .status_in_frame(_unused_core_status_in_frame),
        .status_protocol_error(core_status_protocol_error)
    );

    video_timing_720p u_video_timing_720p (
        .pix_clk,
        .pix_reset,
        .h_count,
        .v_count,
        .active_video,
        .hsync,
        .vsync
    );

    axis_to_raster #(
        .ACTIVE_WIDTH(1280),
        .ACTIVE_HEIGHT(720),
        .H_TOTAL(1650),
        .V_TOTAL(750)
    ) u_axis_to_raster (
        .pix_clk,
        .pix_reset,

        .s_axis_tdata(core_tdata),
        .s_axis_tvalid(core_tvalid),
        .s_axis_tready(core_tready),
        .s_axis_tuser(core_tuser),
        .s_axis_tlast(core_tlast),

        .h_count,
        .v_count,
        .active_video,
        .raster_rgb,

        .status_frame_locked(raster_status_frame_locked),
        .status_overflow(raster_status_overflow),
        .status_malformed_line(raster_status_malformed_line),
        .status_underflow(raster_status_underflow),
        .status_black_fallback(raster_status_black_fallback)
    );

    tmds_encoder u_tmds_blue_encoder (
        .pix_clk,
        .pix_reset,
        .video_data(raster_rgb[7:0]),
        .control_data({vsync, hsync}),
        .video_enable(active_video),
        .tmds_data(tmds_blue)
    );

    tmds_encoder u_tmds_green_encoder (
        .pix_clk,
        .pix_reset,
        .video_data(raster_rgb[15:8]),
        .control_data(2'b00),
        .video_enable(active_video),
        .tmds_data(tmds_green)
    );

    tmds_encoder u_tmds_red_encoder (
        .pix_clk,
        .pix_reset,
        .video_data(raster_rgb[23:16]),
        .control_data(2'b00),
        .video_enable(active_video),
        .tmds_data(tmds_red)
    );

    tmds_serializer u_tmds_blue_serializer (
        .pix_clk,
        .tmds_clk_5x,
        .pix_reset,
        .tmds_reset,
        .tmds_word(tmds_blue),
        .tmds_p(hdmi_data_p[0]),
        .tmds_n(hdmi_data_n[0])
    );

    tmds_serializer u_tmds_green_serializer (
        .pix_clk,
        .tmds_clk_5x,
        .pix_reset,
        .tmds_reset,
        .tmds_word(tmds_green),
        .tmds_p(hdmi_data_p[1]),
        .tmds_n(hdmi_data_n[1])
    );

    tmds_serializer u_tmds_red_serializer (
        .pix_clk,
        .tmds_clk_5x,
        .pix_reset,
        .tmds_reset,
        .tmds_word(tmds_red),
        .tmds_p(hdmi_data_p[2]),
        .tmds_n(hdmi_data_n[2])
    );

    // Serializing the forwarded-clock word through the same primitive and
    // clock network as the data lanes keeps their phase relationship explicit.
    tmds_serializer u_tmds_clock_serializer (
        .pix_clk,
        .tmds_clk_5x,
        .pix_reset,
        .tmds_reset,
        .tmds_word(TMDS_CLOCK_WORD),
        .tmds_p(hdmi_clk_p),
        .tmds_n(hdmi_clk_n)
    );

endmodule
