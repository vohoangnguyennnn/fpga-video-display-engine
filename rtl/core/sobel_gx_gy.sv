// Stall-aware two-stage Sobel gradient pipeline.
//
// Stage 1 forms the positive and negative coefficient lobes for each axis.
// Stage 2 subtracts those unsigned lobe sums into signed 12-bit gradients.
// Magnitude, saturation, thresholding, and border policy belong downstream.

module sobel_gx_gy (
    input logic aclk,
    input logic aresetn,

    input logic [7:0] s_window_p00,
    input logic [7:0] s_window_p01,
    input logic [7:0] s_window_p02,
    input logic [7:0] s_window_p10,
    input logic [7:0] s_window_p11,
    input logic [7:0] s_window_p12,
    input logic [7:0] s_window_p20,
    input logic [7:0] s_window_p21,
    input logic [7:0] s_window_p22,
    input logic s_window_valid,
    output logic s_window_ready,

    output logic signed [11:0] m_gradient_gx,
    output logic signed [11:0] m_gradient_gy,
    output logic m_gradient_valid,
    input logic m_gradient_ready
);

    localparam integer MAX_GRADIENT = 4 * 255;
    localparam integer MAX_SIGNED_12BIT = (1 << 11) - 1;

    logic [10:0] gx_positive_sum;
    logic [10:0] gx_negative_sum;
    logic [10:0] gy_positive_sum;
    logic [10:0] gy_negative_sum;

    logic [10:0] stage1_gx_positive_q;
    logic [10:0] stage1_gx_negative_q;
    logic [10:0] stage1_gy_positive_q;
    logic [10:0] stage1_gy_negative_q;
    logic stage1_valid_q;

    logic signed [11:0] gx_difference;
    logic signed [11:0] gy_difference;
    logic signed [11:0] stage2_gx_q;
    logic signed [11:0] stage2_gy_q;
    logic stage2_valid_q;

    logic stage1_ready;
    logic stage2_ready;
    logic _unused_center_pixel;

    initial begin
        assert (MAX_GRADIENT <= MAX_SIGNED_12BIT)
            else $fatal(1, "Sobel gradient must fit in signed 12 bits");
    end

    // All terms are explicitly widened before shifting or addition.
    assign gx_positive_sum = {3'd0, s_window_p02} + ({3'd0, s_window_p12} << 1) + {3'd0, s_window_p22};
    assign gx_negative_sum = {3'd0, s_window_p00} + ({3'd0, s_window_p10} << 1) + {3'd0, s_window_p20};
    assign gy_positive_sum = {3'd0, s_window_p00} + ({3'd0, s_window_p01} << 1) + {3'd0, s_window_p02};
    assign gy_negative_sum = {3'd0, s_window_p20} + ({3'd0, s_window_p21} << 1) + {3'd0, s_window_p22};

    // A leading zero makes each lobe a positive signed 12-bit operand.
    assign gx_difference = $signed({1'b0, stage1_gx_positive_q}) - $signed({1'b0, stage1_gx_negative_q});
    assign gy_difference = $signed({1'b0, stage1_gy_positive_q}) - $signed({1'b0, stage1_gy_negative_q});

    assign stage2_ready = !stage2_valid_q || m_gradient_ready;
    assign stage1_ready = !stage1_valid_q || stage2_ready;

    assign s_window_ready = stage1_ready;
    assign m_gradient_gx = stage2_gx_q;
    assign m_gradient_gy = stage2_gy_q;
    assign m_gradient_valid = stage2_valid_q;

    // The center coefficient is zero in both Sobel kernels.
    assign _unused_center_pixel = &{1'b0, s_window_p11};

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            stage1_valid_q <= 1'b0;
            stage2_valid_q <= 1'b0;
        end else begin
            if (stage2_ready) begin
                stage2_valid_q <= stage1_valid_q;
                if (stage1_valid_q) begin
                    stage2_gx_q <= gx_difference;
                    stage2_gy_q <= gy_difference;
                end
            end

            if (stage1_ready) begin
                stage1_valid_q <= s_window_valid;
                if (s_window_valid) begin
                    stage1_gx_positive_q <= gx_positive_sum;
                    stage1_gx_negative_q <= gx_negative_sum;
                    stage1_gy_positive_q <= gy_positive_sum;
                    stage1_gy_negative_q <= gy_negative_sum;
                end
            end
        end
    end

endmodule
