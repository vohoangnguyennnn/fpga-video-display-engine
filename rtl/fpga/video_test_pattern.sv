// Handshake-driven 1280x720 RGB888 test-pattern source.
//
// The logical AXI frame contains active pixels only; it has no raster blanking.
// A composite image exposes color, grayscale, spatial-edge, and motion behavior
// without a camera or frame buffer.

module video_test_pattern (
    input logic pix_clk,
    input logic pix_reset,

    output logic [23:0] m_axis_tdata,
    output logic m_axis_tvalid,
    input logic m_axis_tready,
    output logic m_axis_tuser,
    output logic m_axis_tlast
);

    localparam logic [10:0] FRAME_WIDTH = 11'd1280;
    localparam logic [9:0] FRAME_HEIGHT = 10'd720;
    localparam logic [10:0] LAST_X = FRAME_WIDTH - 1'b1;
    localparam logic [9:0] LAST_Y = FRAME_HEIGHT - 1'b1;

    localparam logic [9:0] COLOR_BAR_END_Y = 10'd180;
    localparam logic [9:0] RED_RAMP_END_Y = 10'd240;
    localparam logic [9:0] GREEN_RAMP_END_Y = 10'd300;
    localparam logic [9:0] BLUE_RAMP_END_Y = 10'd360;
    localparam logic [9:0] CHECKER_END_Y = 10'd540;

    localparam logic [10:0] MOTION_SIZE = 11'd64;
    localparam logic [10:0] MOTION_STEP = 11'd4;
    localparam logic [10:0] MOTION_MAX_X = FRAME_WIDTH - MOTION_SIZE;
    localparam logic [9:0] MOTION_TOP_Y = 10'd328;
    localparam logic [9:0] MOTION_BOTTOM_Y = MOTION_TOP_Y + MOTION_SIZE[9:0];

    logic [10:0] x_count_q;
    logic [9:0] y_count_q;
    logic [10:0] motion_x_q;

    logic [2:0] _unused_ramp_quotient_msb;
    logic [7:0] ramp_value;
    logic checker_white;
    logic [5:0] diagonal_phase;
    logic [10:0] motion_end_x;
    logic inside_motion_shape;
    logic [23:0] pattern_pixel;
    logic transfer;

    assign m_axis_tvalid = !pix_reset;
    assign m_axis_tuser = m_axis_tvalid && (x_count_q == 0) && (y_count_q == 0);
    assign m_axis_tlast = m_axis_tvalid && (x_count_q == LAST_X);
    assign m_axis_tdata = pattern_pixel;
    assign transfer = m_axis_tvalid && m_axis_tready;

    // 1280 / 256 = 5, so one grayscale step spans exactly five pixels.
    assign {_unused_ramp_quotient_msb, ramp_value} = x_count_q / 11'd5;

    assign checker_white = x_count_q[5] ^ y_count_q[5];
    assign diagonal_phase = x_count_q[5:0] + y_count_q[5:0];

    assign motion_end_x = motion_x_q + MOTION_SIZE;
    assign inside_motion_shape = (x_count_q >= motion_x_q) && (x_count_q < motion_end_x) && (y_count_q >= MOTION_TOP_Y) && (y_count_q < MOTION_BOTTOM_Y);

    always_comb begin
        pattern_pixel = 24'h000000;

        if (!pix_reset) begin
            if (y_count_q < COLOR_BAR_END_Y) begin
                if (x_count_q < 160) begin
                    pattern_pixel = 24'hFFFFFF;
                end else if (x_count_q < 320) begin
                    pattern_pixel = 24'hFFFF00;
                end else if (x_count_q < 480) begin
                    pattern_pixel = 24'h00FFFF;
                end else if (x_count_q < 640) begin
                    pattern_pixel = 24'h00FF00;
                end else if (x_count_q < 800) begin
                    pattern_pixel = 24'hFF00FF;
                end else if (x_count_q < 960) begin
                    pattern_pixel = 24'hFF0000;
                end else if (x_count_q < 1120) begin
                    pattern_pixel = 24'h0000FF;
                end
            end else if (y_count_q < RED_RAMP_END_Y) begin
                pattern_pixel = {ramp_value, 16'h0000};
            end else if (y_count_q < GREEN_RAMP_END_Y) begin
                pattern_pixel = {8'h00, ramp_value, 8'h00};
            end else if (y_count_q < BLUE_RAMP_END_Y) begin
                pattern_pixel = {16'h0000, ramp_value};
            end else if (y_count_q < CHECKER_END_Y) begin
                pattern_pixel = checker_white ? 24'hFFFFFF : 24'h000000;
            end else begin
                pattern_pixel = (diagonal_phase < 3) ? 24'hFFFFFF : 24'h001020;
            end

            // A 64x64 orange square moves four pixels per completed frame.
            if (inside_motion_shape) begin
                pattern_pixel = 24'hFF8000;
            end
        end
    end

    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            x_count_q <= '0;
            y_count_q <= '0;
            motion_x_q <= '0;
        end else if (transfer) begin
            if (x_count_q == LAST_X) begin
                x_count_q <= '0;

                if (y_count_q == LAST_Y) begin
                    y_count_q <= '0;

                    if (motion_x_q >= MOTION_MAX_X) begin
                        motion_x_q <= '0;
                    end else begin
                        motion_x_q <= motion_x_q + MOTION_STEP;
                    end
                end else begin
                    y_count_q <= y_count_q + 1'b1;
                end
            end else begin
                x_count_q <= x_count_q + 1'b1;
            end
        end
    end

endmodule
