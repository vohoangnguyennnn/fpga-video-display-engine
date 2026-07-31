// Stall-aware two-stage Sobel magnitude and threshold pipeline.
//
// Stage 1 converts signed gradients to unsigned absolute values and captures
// the active threshold. Stage 2 forms the L1 magnitude, saturates it to eight
// bits, and performs the specified strict comparison against threshold * 6.

module sobel_magnitude (
    input logic aclk,
    input logic aresetn,

    input logic signed [11:0] s_gradient_gx,
    input logic signed [11:0] s_gradient_gy,
    input logic s_gradient_valid,
    output logic s_gradient_ready,

    input logic [7:0] active_threshold,

    output logic [7:0] m_sobel_magnitude,
    output logic [7:0] m_sobel_edge,
    output logic m_sobel_valid,
    input logic m_sobel_ready
);

    localparam integer MAX_GRADIENT = 4 * 255;
    localparam integer MAX_ABSOLUTE_SUM = 2 * MAX_GRADIENT;
    localparam integer MAX_REACHABLE_MAGNITUDE = 1530;
    localparam integer MAX_11BIT_VALUE = (1 << 11) - 1;

    logic [11:0] gx_twos_complement;
    logic [11:0] gy_twos_complement;
    logic [10:0] gx_absolute;
    logic [10:0] gy_absolute;
    logic _unused_gx_absolute_high;
    logic _unused_gy_absolute_high;

    logic [10:0] stage1_gx_absolute_q;
    logic [10:0] stage1_gy_absolute_q;
    logic [7:0] stage1_threshold_q;
    logic stage1_valid_q;

    logic [10:0] magnitude_11bit;
    logic [10:0] threshold_11bit;
    logic [7:0] saturated_magnitude;
    logic [7:0] thresholded_edge;

    logic [7:0] stage2_magnitude_q;
    logic [7:0] stage2_edge_q;
    logic stage2_valid_q;

    logic stage1_ready;
    logic stage2_ready;

    initial begin
        assert (MAX_ABSOLUTE_SUM <= MAX_11BIT_VALUE)
            else $fatal(1, "Sobel L1 magnitude must fit in 11 bits");
        assert (MAX_REACHABLE_MAGNITUDE == (255 * 6))
            else $fatal(1, "Reachable Sobel magnitude bound must be 1530");
        assert (MAX_REACHABLE_MAGNITUDE <= MAX_11BIT_VALUE)
            else $fatal(1, "Reachable Sobel magnitude must fit in 11 bits");
    end

    // Negation is performed at the full signed-input width. Legal Sobel
    // gradients are limited to +/-1020, so the result always fits in 11 bits.
    assign gx_twos_complement = (~$unsigned(s_gradient_gx)) + 12'd1;
    assign gy_twos_complement = (~$unsigned(s_gradient_gy)) + 12'd1;
    assign {_unused_gx_absolute_high, gx_absolute} = s_gradient_gx[11] ? gx_twos_complement : $unsigned(s_gradient_gx);
    assign {_unused_gy_absolute_high, gy_absolute} = s_gradient_gy[11] ? gy_twos_complement : $unsigned(s_gradient_gy);

    assign magnitude_11bit = stage1_gx_absolute_q + stage1_gy_absolute_q;

    // Both threshold shift operands are widened to 11 bits before shifting.
    assign threshold_11bit = ({3'd0, stage1_threshold_q} << 2) + ({3'd0, stage1_threshold_q} << 1);

    assign saturated_magnitude = (magnitude_11bit > 11'd255) ? 8'hff : magnitude_11bit[7:0];
    assign thresholded_edge = (magnitude_11bit > threshold_11bit) ? 8'hff : 8'h00;

    assign stage2_ready = !stage2_valid_q || m_sobel_ready;
    assign stage1_ready = !stage1_valid_q || stage2_ready;

    assign s_gradient_ready = stage1_ready;
    assign m_sobel_magnitude = stage2_magnitude_q;
    assign m_sobel_edge = stage2_edge_q;
    assign m_sobel_valid = stage2_valid_q;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            stage1_valid_q <= 1'b0;
            stage2_valid_q <= 1'b0;
        end else begin
            if (stage2_ready) begin
                stage2_valid_q <= stage1_valid_q;
                if (stage1_valid_q) begin
                    stage2_magnitude_q <= saturated_magnitude;
                    stage2_edge_q <= thresholded_edge;
                end
            end

            if (stage1_ready) begin
                stage1_valid_q <= s_gradient_valid;
                if (s_gradient_valid) begin
                    stage1_gx_absolute_q <= gx_absolute;
                    stage1_gy_absolute_q <= gy_absolute;
                    stage1_threshold_q <= active_threshold;
                end
            end
        end
    end

endmodule
