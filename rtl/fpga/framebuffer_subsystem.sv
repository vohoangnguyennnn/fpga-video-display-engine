// SPDX-License-Identifier: MIT
//
// Two-slot DDR3 framebuffer subsystem.
//
// This module is intentionally a thin integration boundary.  It owns the
// framebuffer controller and the two unidirectional DMA engines, but it does
// not contain the MIG, AXI interconnect, BIST, raster timing, or video
// processing core.  The write and read AXI ports are kept separate so that
// they can be connected to independent slave ports of the AXI interconnect.

module framebuffer_subsystem #(
    parameter integer FRAME_WIDTH      = framebuffer_pkg::FRAME_WIDTH,
    parameter integer FRAME_HEIGHT     = framebuffer_pkg::FRAME_HEIGHT,
    parameter integer STRIDE_BYTES     = framebuffer_pkg::STRIDE_BYTES,
    parameter logic [28:0] FB0_BASE_ADDR = 29'(framebuffer_pkg::FB0_BASE_ADDR),
    parameter logic [28:0] FB1_BASE_ADDR = 29'(framebuffer_pkg::FB1_BASE_ADDR),
    parameter integer FB_SLOT_BYTES    = framebuffer_pkg::FB_SLOT_BYTES,
    parameter integer BURST_BEATS      = framebuffer_pkg::DMA_BURST_BEATS,
    parameter integer WRITE_FIFO_DEPTH = 512,
    parameter integer READ_FIFO_DEPTH  = 512,
    parameter integer READ_START_THRESHOLD_BEATS = 256,
    parameter logic [3:0]  WRITE_AXI_ID        = 4'h1,
    parameter logic [3:0]  READ_AXI_ID         = 4'h2,
    // Diagnostic-only instrumentation. The release/production build leaves
    // this disabled so the monitor is pruned completely.
    parameter bit ENABLE_PERF_MONITOR = 1'b0,
    parameter integer PERF_MAX_WINDOW_CYCLES = 1_333_333
) (
    // Pixel/stream clock domain.
    input  logic         pix_clk,
    input  logic         pix_reset,
    // One-cycle event at raster coordinate (h=0, v=FRAME_HEIGHT).
    input  logic         vblank_start,

    // Source input frame written to DDR3.
    input  logic [23:0]  s_axis_tdata,
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic         s_axis_tuser,
    input  logic         s_axis_tlast,

    // Frame read from DDR3 and sent to the video-processing core.
    output logic [23:0]  m_axis_tdata,
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic         m_axis_tuser,
    output logic         m_axis_tlast,
    output logic         display_valid_pix,

    // MIG UI clock domain.  ui_reset must remain asserted until calibration
    // and the optional boot-time BIST have completed successfully.
    input  logic         ui_clk,
    input  logic         ui_reset,

    // Write-DMA AXI4 master (write channels only).
    output logic [3:0]   m_axi_wdma_awid,
    output logic [28:0]  m_axi_wdma_awaddr,
    output logic [7:0]   m_axi_wdma_awlen,
    output logic [2:0]   m_axi_wdma_awsize,
    output logic [1:0]   m_axi_wdma_awburst,
    output logic [0:0]   m_axi_wdma_awlock,
    output logic [3:0]   m_axi_wdma_awcache,
    output logic [2:0]   m_axi_wdma_awprot,
    output logic [3:0]   m_axi_wdma_awqos,
    output logic         m_axi_wdma_awvalid,
    input  logic         m_axi_wdma_awready,

    output logic [127:0] m_axi_wdma_wdata,
    output logic [15:0]  m_axi_wdma_wstrb,
    output logic         m_axi_wdma_wlast,
    output logic         m_axi_wdma_wvalid,
    input  logic         m_axi_wdma_wready,

    input  logic [3:0]   m_axi_wdma_bid,
    input  logic [1:0]   m_axi_wdma_bresp,
    input  logic         m_axi_wdma_bvalid,
    output logic         m_axi_wdma_bready,

    // Read-DMA AXI4 master (read channels only).
    output logic [3:0]   m_axi_rdma_arid,
    output logic [28:0]  m_axi_rdma_araddr,
    output logic [7:0]   m_axi_rdma_arlen,
    output logic [2:0]   m_axi_rdma_arsize,
    output logic [1:0]   m_axi_rdma_arburst,
    output logic [0:0]   m_axi_rdma_arlock,
    output logic [3:0]   m_axi_rdma_arcache,
    output logic [2:0]   m_axi_rdma_arprot,
    output logic [3:0]   m_axi_rdma_arqos,
    output logic         m_axi_rdma_arvalid,
    input  logic         m_axi_rdma_arready,

    input  logic [3:0]   m_axi_rdma_rid,
    input  logic [127:0] m_axi_rdma_rdata,
    input  logic [1:0]   m_axi_rdma_rresp,
    input  logic         m_axi_rdma_rlast,
    input  logic         m_axi_rdma_rvalid,
    output logic         m_axi_rdma_rready,

    // Compact status/ILA interface.
    output logic         status_write_busy,
    output logic         status_write_frame_done,
    output logic         status_write_frame_success,
    output logic         status_read_busy,
    output logic         status_read_fetch_done,
    output logic         status_read_fetch_success,
    output logic         status_read_frame_done,
    output logic         status_read_frame_success,
    output logic         status_display_valid,
    output logic         status_swap,
    output logic         status_repeat_frame,
    output logic         status_fault,
    output logic         front_buffer_index,
    output logic         back_buffer_index,
    output logic [1:0]   slot0_state,
    output logic [1:0]   slot1_state,

    // UI-domain diagnostic snapshot. These ports are constant zero unless
    // ENABLE_PERF_MONITOR is selected at build time.
    output logic         debug_measurement_active,
    output logic         debug_measurement_valid,
    output logic         debug_bandwidth_pass,
    output logic [31:0]  debug_window_cycles,
    output logic [31:0]  debug_write_beats,
    output logic [31:0]  debug_read_beats,
    output logic [31:0]  debug_write_stall_cycles,
    output logic [31:0]  debug_read_stall_cycles,
    output logic [31:0]  debug_measurement_count,
    output logic         debug_swap_interval_valid,
    output logic [31:0]  debug_swap_interval_cycles,
    output logic [31:0]  debug_swap_count,
    output logic [31:0]  debug_repeat_count
);

    logic       wdma_cmd_valid;
    logic       wdma_cmd_ready;
    logic       wdma_cmd_buffer_index;

    logic       rdma_cmd_valid;
    logic       rdma_cmd_ready;
    logic       rdma_cmd_buffer_index;

    logic       wdma_axi_error;
    logic       wdma_protocol_error;
    logic       rdma_axi_error;
    logic       rdma_protocol_error;

    logic       control_write_error;
    logic       control_read_error;
    logic       control_read_deadline_miss;
    logic       control_ownership_error;

    framebuffer_control u_framebuffer_control (
        .pix_clk                       (pix_clk),
        .pix_reset                     (pix_reset),
        .vblank_start                  (vblank_start),
        .display_valid_pix             (display_valid_pix),

        .ui_clk                        (ui_clk),
        .ui_reset                      (ui_reset),

        .wdma_cmd_valid                (wdma_cmd_valid),
        .wdma_cmd_ready                (wdma_cmd_ready),
        .wdma_cmd_buffer_index         (wdma_cmd_buffer_index),
        .wdma_status_frame_done        (status_write_frame_done),
        .wdma_status_frame_success     (status_write_frame_success),

        .rdma_cmd_valid                (rdma_cmd_valid),
        .rdma_cmd_ready                (rdma_cmd_ready),
        .rdma_cmd_buffer_index         (rdma_cmd_buffer_index),
        .rdma_status_frame_done        (status_read_frame_done),
        .rdma_status_frame_success     (status_read_frame_success),

        .front_buffer_index            (front_buffer_index),
        .back_buffer_index             (back_buffer_index),
        .slot0_state                   (slot0_state),
        .slot1_state                   (slot1_state),
        .status_display_valid          (status_display_valid),
        .status_swap                   (status_swap),
        .status_repeat_frame           (status_repeat_frame),
        .status_write_error            (control_write_error),
        .status_read_error             (control_read_error),
        .status_read_deadline_miss     (control_read_deadline_miss),
        .status_ownership_error        (control_ownership_error)
    );

    framebuffer_write_dma #(
        .FRAME_WIDTH                   (FRAME_WIDTH),
        .FRAME_HEIGHT                  (FRAME_HEIGHT),
        .STRIDE_BYTES                  (STRIDE_BYTES),
        .FB0_BASE_ADDR                 (FB0_BASE_ADDR),
        .FB1_BASE_ADDR                 (FB1_BASE_ADDR),
        .FB_SLOT_BYTES                 (FB_SLOT_BYTES),
        .BURST_BEATS                   (BURST_BEATS),
        .FIFO_DEPTH                    (WRITE_FIFO_DEPTH),
        .AXI_ID                        (WRITE_AXI_ID)
    ) u_framebuffer_write_dma (
        .pix_clk                       (pix_clk),
        .pix_reset                     (pix_reset),
        .s_axis_tdata                  (s_axis_tdata),
        .s_axis_tvalid                 (s_axis_tvalid),
        .s_axis_tready                 (s_axis_tready),
        .s_axis_tuser                  (s_axis_tuser),
        .s_axis_tlast                  (s_axis_tlast),

        .ui_clk                        (ui_clk),
        .ui_reset                      (ui_reset),
        .cmd_valid                     (wdma_cmd_valid),
        .cmd_ready                     (wdma_cmd_ready),
        .cmd_buffer_index              (wdma_cmd_buffer_index),
        .status_busy                   (status_write_busy),
        .status_frame_done             (status_write_frame_done),
        .status_frame_success          (status_write_frame_success),
        .status_axi_error              (wdma_axi_error),
        .status_protocol_error         (wdma_protocol_error),
        .first_error_kind              (),
        .first_error_addr              (),
        .first_error_resp              (),

        .m_axi_awid                    (m_axi_wdma_awid),
        .m_axi_awaddr                  (m_axi_wdma_awaddr),
        .m_axi_awlen                   (m_axi_wdma_awlen),
        .m_axi_awsize                  (m_axi_wdma_awsize),
        .m_axi_awburst                 (m_axi_wdma_awburst),
        .m_axi_awlock                  (m_axi_wdma_awlock),
        .m_axi_awcache                 (m_axi_wdma_awcache),
        .m_axi_awprot                  (m_axi_wdma_awprot),
        .m_axi_awqos                   (m_axi_wdma_awqos),
        .m_axi_awvalid                 (m_axi_wdma_awvalid),
        .m_axi_awready                 (m_axi_wdma_awready),
        .m_axi_wdata                   (m_axi_wdma_wdata),
        .m_axi_wstrb                   (m_axi_wdma_wstrb),
        .m_axi_wlast                   (m_axi_wdma_wlast),
        .m_axi_wvalid                  (m_axi_wdma_wvalid),
        .m_axi_wready                  (m_axi_wdma_wready),
        .m_axi_bid                     (m_axi_wdma_bid),
        .m_axi_bresp                   (m_axi_wdma_bresp),
        .m_axi_bvalid                  (m_axi_wdma_bvalid),
        .m_axi_bready                  (m_axi_wdma_bready)
    );

    framebuffer_read_dma #(
        .FRAME_WIDTH                   (FRAME_WIDTH),
        .FRAME_HEIGHT                  (FRAME_HEIGHT),
        .STRIDE_BYTES                  (STRIDE_BYTES),
        .FB0_BASE_ADDR                 (FB0_BASE_ADDR),
        .FB1_BASE_ADDR                 (FB1_BASE_ADDR),
        .FB_SLOT_BYTES                 (FB_SLOT_BYTES),
        .BURST_BEATS                   (BURST_BEATS),
        .FIFO_DEPTH                    (READ_FIFO_DEPTH),
        .START_THRESHOLD_BEATS         (READ_START_THRESHOLD_BEATS),
        .AXI_ID                        (READ_AXI_ID)
    ) u_framebuffer_read_dma (
        .ui_clk                        (ui_clk),
        .ui_reset                      (ui_reset),
        .cmd_valid                     (rdma_cmd_valid),
        .cmd_ready                     (rdma_cmd_ready),
        .cmd_buffer_index              (rdma_cmd_buffer_index),
        .status_busy                   (status_read_busy),
        .status_fetch_done             (status_read_fetch_done),
        .status_fetch_success          (status_read_fetch_success),
        .status_frame_done             (status_read_frame_done),
        .status_frame_success          (status_read_frame_success),
        .status_axi_error              (rdma_axi_error),
        .status_protocol_error         (rdma_protocol_error),
        .first_error_kind              (),
        .first_error_addr              (),
        .first_error_resp              (),

        .m_axi_arid                    (m_axi_rdma_arid),
        .m_axi_araddr                  (m_axi_rdma_araddr),
        .m_axi_arlen                   (m_axi_rdma_arlen),
        .m_axi_arsize                  (m_axi_rdma_arsize),
        .m_axi_arburst                 (m_axi_rdma_arburst),
        .m_axi_arlock                  (m_axi_rdma_arlock),
        .m_axi_arcache                 (m_axi_rdma_arcache),
        .m_axi_arprot                  (m_axi_rdma_arprot),
        .m_axi_arqos                   (m_axi_rdma_arqos),
        .m_axi_arvalid                 (m_axi_rdma_arvalid),
        .m_axi_arready                 (m_axi_rdma_arready),
        .m_axi_rid                     (m_axi_rdma_rid),
        .m_axi_rdata                   (m_axi_rdma_rdata),
        .m_axi_rresp                   (m_axi_rdma_rresp),
        .m_axi_rlast                   (m_axi_rdma_rlast),
        .m_axi_rvalid                  (m_axi_rdma_rvalid),
        .m_axi_rready                  (m_axi_rdma_rready),

        .pix_clk                       (pix_clk),
        .pix_reset                     (pix_reset),
        .m_axis_tdata                  (m_axis_tdata),
        .m_axis_tvalid                 (m_axis_tvalid),
        .m_axis_tready                 (m_axis_tready),
        .m_axis_tuser                  (m_axis_tuser),
        .m_axis_tlast                  (m_axis_tlast)
    );

    // Every term below is sticky until ui_reset, so the aggregate is sticky
    // without adding a second fault register.
    assign status_fault = wdma_axi_error
                        | wdma_protocol_error
                        | rdma_axi_error
                        | rdma_protocol_error
                        | control_write_error
                        | control_read_error
                        | control_read_deadline_miss
                        | control_ownership_error;

    generate
        if (ENABLE_PERF_MONITOR) begin : g_perf_monitor
            framebuffer_perf_monitor #(
                .FRAME_BYTES(FRAME_HEIGHT * STRIDE_BYTES),
                .AXI_DATA_BYTES(framebuffer_pkg::AXI_DATA_BYTES),
                .MAX_WINDOW_CYCLES(PERF_MAX_WINDOW_CYCLES)
            ) u_framebuffer_perf_monitor (
                .ui_clk,
                .ui_reset,
                .swap_start(status_swap),
                .repeat_frame(status_repeat_frame),
                .write_data_valid(m_axi_wdma_wvalid),
                .write_data_ready(m_axi_wdma_wready),
                .read_data_valid(m_axi_rdma_rvalid),
                .read_data_ready(m_axi_rdma_rready),
                .write_frame_done(status_write_frame_done),
                .write_frame_success(status_write_frame_success),
                .read_fetch_done(status_read_fetch_done),
                .read_fetch_success(status_read_fetch_success),
                .debug_measurement_active,
                .debug_measurement_valid,
                .debug_bandwidth_pass,
                .debug_window_cycles,
                .debug_write_beats,
                .debug_read_beats,
                .debug_write_stall_cycles,
                .debug_read_stall_cycles,
                .debug_measurement_count,
                .debug_swap_interval_valid,
                .debug_swap_interval_cycles,
                .debug_swap_count,
                .debug_repeat_count
            );
        end else begin : g_no_perf_monitor
            assign debug_measurement_active = 1'b0;
            assign debug_measurement_valid = 1'b0;
            assign debug_bandwidth_pass = 1'b0;
            assign debug_window_cycles = 32'd0;
            assign debug_write_beats = 32'd0;
            assign debug_read_beats = 32'd0;
            assign debug_write_stall_cycles = 32'd0;
            assign debug_read_stall_cycles = 32'd0;
            assign debug_measurement_count = 32'd0;
            assign debug_swap_interval_valid = 1'b0;
            assign debug_swap_interval_cycles = 32'd0;
            assign debug_swap_count = 32'd0;
            assign debug_repeat_count = 32'd0;
        end
    endgenerate

endmodule
