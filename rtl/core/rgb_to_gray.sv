// Stall-aware, two-stage RGB888-to-grayscale pipeline.
//
// Stage 1 registers the three unsigned coefficient products. Stage 2 adds the
// products and rounding term, then updates only the gray field. The remaining
// payload fields stay transactionally aligned through arbitrary backpressure.

module rgb_to_gray
    import video_pkg::video_payload_t;
(
    input logic aclk,
    input logic aresetn,

    input video_payload_t s_axis_payload,
    input logic s_axis_tvalid,
    output logic s_axis_tready,

    output video_payload_t m_axis_payload,
    output logic m_axis_tvalid,
    input logic m_axis_tready
);

    localparam integer RED_COEFFICIENT = 77;
    localparam integer GREEN_COEFFICIENT = 150;
    localparam integer BLUE_COEFFICIENT = 29;
    localparam integer ROUNDING_TERM = 128;

    localparam integer COEFFICIENT_SUM = RED_COEFFICIENT + GREEN_COEFFICIENT + BLUE_COEFFICIENT;
    localparam integer MAX_WEIGHTED_SUM = (COEFFICIENT_SUM * 255) + ROUNDING_TERM;

    video_payload_t stage1_payload_q;
    video_payload_t stage2_payload_q;
    video_payload_t converted_payload;

    logic [15:0] red_product_q;
    logic [15:0] green_product_q;
    logic [15:0] blue_product_q;
    logic [7:0] gray_value;
    logic [7:0] _unused_weighted_fraction;

    logic stage1_valid_q;
    logic stage2_valid_q;
    logic stage1_ready;
    logic stage2_ready;

    initial begin
        assert (COEFFICIENT_SUM == 256)
            else $fatal(1, "RGB-to-gray coefficients must sum to 256");
        assert (MAX_WEIGHTED_SUM <= 65535)
            else $fatal(1, "RGB-to-gray weighted sum must fit in 16 bits");
        assert ((MAX_WEIGHTED_SUM >> 8) == 255)
            else $fatal(1, "Maximum rounded grayscale value must be 255");
    end

    assign stage2_ready = !stage2_valid_q || m_axis_tready;
    assign stage1_ready = !stage1_valid_q || stage2_ready;

    assign s_axis_tready = stage1_ready;
    assign m_axis_payload = stage2_payload_q;
    assign m_axis_tvalid = stage2_valid_q;

    assign {gray_value, _unused_weighted_fraction} = red_product_q + green_product_q + blue_product_q + ROUNDING_TERM[15:0];

    always_comb begin
        converted_payload = stage1_payload_q;
        converted_payload.gray = gray_value;
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            stage1_valid_q <= 1'b0;
            stage2_valid_q <= 1'b0;
        end else begin
            if (stage2_ready) begin
                stage2_valid_q <= stage1_valid_q;
                if (stage1_valid_q) begin
                    stage2_payload_q <= converted_payload;
                end
            end

            if (stage1_ready) begin
                stage1_valid_q <= s_axis_tvalid;
                if (s_axis_tvalid) begin
                    stage1_payload_q <= s_axis_payload;
                    red_product_q <= {8'd0, s_axis_payload.rgb[23:16]} * RED_COEFFICIENT[15:0];
                    green_product_q <= {8'd0, s_axis_payload.rgb[15:8]} * GREEN_COEFFICIENT[15:0];
                    blue_product_q <= {8'd0, s_axis_payload.rgb[7:0]} * BLUE_COEFFICIENT[15:0];
                end
            end
        end
    end

endmodule
