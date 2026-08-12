// Fixed-function DDR3 framebuffer geometry and memory-layout contract.
//
// These constants intentionally are not parameters or runtime registers. The
// v2.0 board image has one reviewed 1280x720 XRGB8888 layout shared by the DMA,
// ownership controller, integration RTL, and verification environment.

package framebuffer_pkg;

    localparam int unsigned FRAME_WIDTH = 1_280;
    localparam int unsigned FRAME_HEIGHT = 720;
    localparam int unsigned BYTES_PER_PIXEL = 4;
    localparam int unsigned STRIDE_BYTES = 32'h0000_1400;

    localparam int unsigned FB0_BASE_ADDR = 32'h0000_0000;
    localparam int unsigned FB1_BASE_ADDR = 32'h0040_0000;
    localparam int unsigned FB_SLOT_BYTES = 32'h0040_0000;
    localparam int unsigned FRAMEBUFFER_COUNT = 2;

    localparam int unsigned AXI_ADDR_WIDTH = 29;
    localparam int unsigned AXI_DATA_BYTES = 16;
    localparam int unsigned AXI_DATA_WIDTH = AXI_DATA_BYTES * 8;
    localparam int unsigned PIXELS_PER_AXI_BEAT =
        AXI_DATA_BYTES / BYTES_PER_PIXEL;
    localparam int unsigned DMA_BURST_BEATS = 16;
    localparam int unsigned DMA_BURST_BYTES =
        DMA_BURST_BEATS * AXI_DATA_BYTES;
    localparam logic [7:0] DMA_BURST_AXLEN = 8'(DMA_BURST_BEATS - 1);
    localparam logic [2:0] AXI_BEAT_SIZE = 3'($clog2(AXI_DATA_BYTES));

    localparam int unsigned ACTIVE_LINE_BYTES =
        FRAME_WIDTH * BYTES_PER_PIXEL;
    localparam int unsigned ACTIVE_FRAME_BYTES =
        FRAME_HEIGHT * STRIDE_BYTES;
    localparam int unsigned FB0_END_ADDR =
        FB0_BASE_ADDR + FB_SLOT_BYTES;
    localparam int unsigned FB1_END_ADDR =
        FB1_BASE_ADDR + FB_SLOT_BYTES;
    localparam int unsigned FRAMEBUFFER_APERTURE_BYTES =
        FB1_END_ADDR - FB0_BASE_ADDR;
    localparam int unsigned MIG_APERTURE_BYTES = 32'h2000_0000;

    // Named invariants are also useful in package-level unit tests and in
    // future subsystem assertions. The static enum below turns a bad edit into
    // an elaboration error instead of a latent address-generation defect.
    localparam bit LINE_LAYOUT_VALID =
        STRIDE_BYTES == ACTIVE_LINE_BYTES;
    localparam bit SLOT_ALIGNMENT_VALID =
        ((FB0_BASE_ADDR % 4_096) == 0)
        && ((FB1_BASE_ADDR % 4_096) == 0)
        && ((FB_SLOT_BYTES % 4_096) == 0);
    localparam bit BEAT_ALIGNMENT_VALID =
        ((FB0_BASE_ADDR % AXI_DATA_BYTES) == 0)
        && ((FB1_BASE_ADDR % AXI_DATA_BYTES) == 0)
        && ((STRIDE_BYTES % AXI_DATA_BYTES) == 0)
        && ((FB_SLOT_BYTES % AXI_DATA_BYTES) == 0);
    localparam bit SLOT_CAPACITY_VALID =
        ACTIVE_FRAME_BYTES <= FB_SLOT_BYTES;
    localparam bit SLOT_NONOVERLAP_VALID =
        FB0_END_ADDR <= FB1_BASE_ADDR;
    localparam bit MIG_APERTURE_VALID =
        (FB0_BASE_ADDR < MIG_APERTURE_BYTES)
        && (FB1_END_ADDR <= MIG_APERTURE_BYTES);
    localparam bit AXI_LAYOUT_VALID =
        (AXI_DATA_WIDTH == (AXI_DATA_BYTES * 8))
        && (MIG_APERTURE_BYTES == (32'd1 << AXI_ADDR_WIDTH))
        && ((AXI_DATA_BYTES % BYTES_PER_PIXEL) == 0)
        && ((4_096 % DMA_BURST_BYTES) == 0);
    localparam bit LAYOUT_VALID =
        LINE_LAYOUT_VALID
        && SLOT_ALIGNMENT_VALID
        && BEAT_ALIGNMENT_VALID
        && SLOT_CAPACITY_VALID
        && SLOT_NONOVERLAP_VALID
        && MIG_APERTURE_VALID
        && AXI_LAYOUT_VALID;

    // SystemVerilog requires enum encodings to be unique. A broken layout
    // makes both encodings zero and therefore fails during elaboration in both
    // Vivado and Verilator, before any DMA can be synthesized.
    typedef enum logic {
        LAYOUT_ASSERT_FALSE = 1'b0,
        LAYOUT_ASSERT_TRUE = LAYOUT_VALID
    } framebuffer_layout_static_assert_t;

    function automatic logic [31:0] pack_xrgb8888(
        input logic [23:0] rgb888
    );
        return {8'h00, rgb888};
    endfunction

    function automatic logic [23:0] unpack_xrgb8888(
        input logic [31:0] xrgb8888
    );
        return xrgb8888[23:0];
    endfunction

endpackage
