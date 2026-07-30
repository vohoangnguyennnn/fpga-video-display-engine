// Two-entry AXI4-Stream elastic buffer for the canonical video payload.
//
// The output slot provides the registered stream stage. The skid slot absorbs
// one additional accepted transfer when downstream backpressure arrives. Input
// ready depends only on registered state, so there is no combinational path
// from m_axis_tready to s_axis_tready.

module axis_elastic_buffer
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

    video_payload_t output_payload_q;
    video_payload_t skid_payload_q;
    logic output_valid_q;
    logic skid_valid_q;

    logic push;
    logic pop;

    // Registered skid occupancy is the only source of input backpressure.
    assign s_axis_tready = !skid_valid_q;

    assign m_axis_payload = output_payload_q;
    assign m_axis_tvalid = output_valid_q;

    assign push = s_axis_tvalid && s_axis_tready;
    assign pop = m_axis_tvalid && m_axis_tready;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            output_valid_q <= 1'b0;
            skid_valid_q <= 1'b0;
        end else begin
            case ({push, pop})
                2'b10: begin
                    if (!output_valid_q) begin
                        output_payload_q <= s_axis_payload;
                        output_valid_q <= 1'b1;
                    end else begin
                        skid_payload_q <= s_axis_payload;
                        skid_valid_q <= 1'b1;
                    end
                end

                2'b01: begin
                    if (skid_valid_q) begin
                        output_payload_q <= skid_payload_q;
                        output_valid_q <= 1'b1;
                        skid_valid_q <= 1'b0;
                    end else begin
                        output_valid_q <= 1'b0;
                    end
                end

                2'b11: begin
                    // The current output is accepted while the next input
                    // replaces it, sustaining one transfer per clock.
                    output_payload_q <= s_axis_payload;
                    output_valid_q <= 1'b1;
                    skid_valid_q <= 1'b0;
                end

                default: begin
                    // Hold both slots when no transfer is accepted.
                end
            endcase
        end
    end

endmodule
