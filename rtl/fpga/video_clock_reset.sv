// Board clock generation and per-domain reset conditioning.
//
// video_clk_wiz is a Vivado Clocking Wizard IP configured for one MMCM:
//   clk_in1      = 50.00000 MHz
//   pix_clk      = 74.21875 MHz
//   tmds_clk_5x  = 371.09375 MHz
//   reset        = active high
//   locked       = enabled
//
// The generated clocks have an exact 5:1 relationship. Each domain remains in
// reset until the MMCM has stayed locked for four edges of that domain.

module video_clock_reset (
    input logic clk_50m,
    input logic reset_async,

    output logic pix_clk,
    output logic tmds_clk_5x,
    output logic pix_reset,
    output logic tmds_reset
);

    logic mmcm_locked;
    logic domain_reset_request;

    // LOCKED is only a reset request source. It never directly resets
    // functional video logic.
    assign domain_reset_request = reset_async || !mmcm_locked;

    video_clk_wiz u_video_clk_wiz (
        .clk_in1(clk_50m),
        .reset(reset_async),
        .locked(mmcm_locked),
        .pix_clk(pix_clk),
        .tmds_clk_5x(tmds_clk_5x)
    );

    reset_sync #(
        .RELEASE_STAGES(4)
    ) u_pix_reset_sync (
        .clk(pix_clk),
        .reset_async(domain_reset_request),
        .reset_out(pix_reset)
    );

    reset_sync #(
        .RELEASE_STAGES(4)
    ) u_tmds_reset_sync (
        .clk(tmds_clk_5x),
        .reset_async(domain_reset_request),
        .reset_out(tmds_reset)
    );

endmodule
