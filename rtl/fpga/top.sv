// MicroPhase A7-LITE R1.1 fixed-function video demonstration top.
//
// DEMO_MODE is a build-time selection:
//   0: direct test pattern -> processing core -> HDMI
//   1: test pattern -> DDR3 double buffer -> processing core -> HDMI
//   2: destructive DDR3 BIST, with video held black
//
// The DDR-backed modes follow a strict boot sequence.  The MIG first reaches
// calibration, the BIST then validates the complete 8-MiB framebuffer
// aperture, and only a passing BIST releases the framebuffer DMA/controller.
// BIST and video DMA therefore never own the AXI fabric at the same time.

module top #(
    parameter integer BUTTON_DEBOUNCE_CYCLES = 1_484_375,
    parameter integer DEMO_MODE = 1,
    // Diagnostic mode only. A normal release bitstream leaves this false and
    // contains neither counters nor ILA preservation nets.
    parameter bit ENABLE_PERF_MONITOR = 1'b0
) (
    input logic clk_50m,

    input logic key_mode_n,
    input logic key_threshold_up_n,

    output logic [2:0] hdmi_data_p,
    output logic [2:0] hdmi_data_n,
    output logic hdmi_clk_p,
    output logic hdmi_clk_n,

    output logic led_frame_locked_n,
    output logic led_fault_n,

    output logic [14:0] ddr3_addr,
    output logic [2:0] ddr3_ba,
    output logic ddr3_ras_n,
    output logic ddr3_cas_n,
    output logic ddr3_we_n,
    output logic ddr3_reset_n,
    output logic [0:0] ddr3_ck_p,
    output logic [0:0] ddr3_ck_n,
    output logic [0:0] ddr3_cke,
    output logic [1:0] ddr3_dm,
    output logic [0:0] ddr3_odt,
    inout wire [15:0] ddr3_dq,
    inout wire [1:0] ddr3_dqs_p,
    inout wire [1:0] ddr3_dqs_n
);

    localparam integer DEMO_MODE_DIRECT = 0;
    localparam integer DEMO_MODE_DDR_VIDEO = 1;
    localparam integer DEMO_MODE_BIST_ONLY = 2;

    localparam logic [15:0] FRAME_WIDTH = 16'd1280;
    localparam logic [15:0] FRAME_HEIGHT = 16'd720;
    localparam logic [9:0] TMDS_CLOCK_WORD = 10'b1111100000;

    logic clk_50m_global;
    logic pix_clk;
    logic tmds_clk_5x;
    logic pix_reset;
    logic core_aresetn;

    logic [1:0] cfg_mode;
    logic [7:0] cfg_threshold;

    logic [23:0] pattern_tdata;
    logic pattern_tvalid;
    logic pattern_tready;
    logic pattern_tuser;
    logic pattern_tlast;

    logic [23:0] core_input_tdata;
    logic core_input_tvalid;
    logic core_input_tready;
    logic core_input_tuser;
    logic core_input_tlast;

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
    logic vblank_start;

    logic [23:0] raster_rgb;
    logic raster_status_frame_locked;
    logic raster_status_overflow;
    logic raster_status_malformed_line;
    logic raster_status_underflow;
    logic raster_status_black_fallback;

    logic ddr_fault_ui;
    logic bist_done_ui;
    logic bist_pass_ui;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic ddr_fault_sync1_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic ddr_fault_sync2_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic bist_done_sync1_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic bist_done_sync2_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic bist_pass_sync1_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic bist_pass_sync2_q;
    logic board_fault_sticky_q;
    logic fault_source_pix;

    logic [9:0] tmds_blue;
    logic [9:0] tmds_green;
    logic [9:0] tmds_red;

    initial begin
        board_fault_sticky_q = 1'b0;

        assert ((DEMO_MODE >= DEMO_MODE_DIRECT)
            && (DEMO_MODE <= DEMO_MODE_BIST_ONLY))
            else $fatal(1, "top DEMO_MODE must be 0, 1, or 2");
        assert (!ENABLE_PERF_MONITOR
            || (DEMO_MODE == DEMO_MODE_DDR_VIDEO))
            else $fatal(1,
                "top performance monitor requires DEMO_MODE=1");
    end

    assign core_aresetn = !pix_reset
        && (DEMO_MODE != DEMO_MODE_BIST_ONLY);
    assign vblank_start = (h_count == 11'd0)
        && (v_count == FRAME_HEIGHT[9:0]);

    // UI-domain sticky faults are synchronized only for board-level status.
    // Event counts and multi-bit telemetry remain in their native domains for
    // optional ILA observation.
    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            ddr_fault_sync1_q <= 1'b0;
            ddr_fault_sync2_q <= 1'b0;
            bist_done_sync1_q <= 1'b0;
            bist_done_sync2_q <= 1'b0;
            bist_pass_sync1_q <= 1'b0;
            bist_pass_sync2_q <= 1'b0;
        end else begin
            ddr_fault_sync1_q <= ddr_fault_ui;
            ddr_fault_sync2_q <= ddr_fault_sync1_q;
            bist_done_sync1_q <= bist_done_ui;
            bist_done_sync2_q <= bist_done_sync1_q;
            bist_pass_sync1_q <= bist_pass_ui;
            bist_pass_sync2_q <= bist_pass_sync1_q;
        end

        // Intentionally no functional-reset clear: a configured image keeps
        // its first board-level failure until the FPGA is reset/reconfigured.
        if (fault_source_pix) begin
            board_fault_sticky_q <= 1'b1;
        end
    end

    assign fault_source_pix = core_status_protocol_error
        || raster_status_overflow
        || raster_status_malformed_line
        || raster_status_underflow
        || raster_status_black_fallback
        || ddr_fault_sync2_q;

    // Both user LEDs are active low.  BIST-only mode deliberately changes the
    // interpretation to done/pass as required by the v2.0 bring-up contract.
    assign led_frame_locked_n = (DEMO_MODE == DEMO_MODE_BIST_ONLY)
        ? !bist_done_sync2_q : !raster_status_frame_locked;
    assign led_fault_n = (DEMO_MODE == DEMO_MODE_BIST_ONLY)
        ? !bist_pass_sync2_q : !board_fault_sticky_q;

    // J19 is buffered exactly once here. All Clocking Wizard IP connected to
    // this net must use Input Source = No buffer.
    board_clock_buffer u_board_clock_buffer (
        .clk_50m_pad(clk_50m),
        .clk_50m_global
    );

    video_clock_reset u_video_clock_reset (
        .clk_50m(clk_50m_global),
        .reset_async(1'b0),
        .pix_clk,
        .tmds_clk_5x,
        .pix_reset
    );

    button_control #(
        .DEBOUNCE_CYCLES(BUTTON_DEBOUNCE_CYCLES),
        .THRESHOLD_STEP(8'd32)
    ) u_button_control (
        .pix_clk,
        .pix_reset,
        .btn_mode(!key_mode_n),
        .btn_threshold_up(!key_threshold_up_n),
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

        .s_axis_tdata(core_input_tdata),
        .s_axis_tvalid(core_input_tvalid),
        .s_axis_tready(core_input_tready),
        .s_axis_tuser(core_input_tuser),
        .s_axis_tlast(core_input_tlast),

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
        .tmds_word(tmds_blue),
        .tmds_p(hdmi_data_p[0]),
        .tmds_n(hdmi_data_n[0])
    );

    tmds_serializer u_tmds_green_serializer (
        .pix_clk,
        .tmds_clk_5x,
        .pix_reset,
        .tmds_word(tmds_green),
        .tmds_p(hdmi_data_p[1]),
        .tmds_n(hdmi_data_n[1])
    );

    tmds_serializer u_tmds_red_serializer (
        .pix_clk,
        .tmds_clk_5x,
        .pix_reset,
        .tmds_word(tmds_red),
        .tmds_p(hdmi_data_p[2]),
        .tmds_n(hdmi_data_n[2])
    );

    tmds_serializer u_tmds_clock_serializer (
        .pix_clk,
        .tmds_clk_5x,
        .pix_reset,
        .tmds_word(TMDS_CLOCK_WORD),
        .tmds_p(hdmi_clk_p),
        .tmds_n(hdmi_clk_n)
    );

    generate
        if (DEMO_MODE == DEMO_MODE_DIRECT) begin : g_direct_mode
            assign core_input_tdata = pattern_tdata;
            assign core_input_tvalid = pattern_tvalid;
            assign pattern_tready = core_input_tready;
            assign core_input_tuser = pattern_tuser;
            assign core_input_tlast = pattern_tlast;

            assign ddr_fault_ui = 1'b0;
            assign bist_done_ui = 1'b0;
            assign bist_pass_ui = 1'b0;

            // Direct mode deliberately has no MIG dependency. Keep the DDR3
            // device inactive and all bidirectional pins high impedance.
            assign ddr3_addr = '0;
            assign ddr3_ba = '0;
            assign ddr3_ras_n = 1'b1;
            assign ddr3_cas_n = 1'b1;
            assign ddr3_we_n = 1'b1;
            assign ddr3_reset_n = 1'b0;
            assign ddr3_ck_p = '0;
            assign ddr3_ck_n = '0;
            assign ddr3_cke = '0;
            assign ddr3_dm = '0;
            assign ddr3_odt = '0;
            assign ddr3_dq = 'z;
            assign ddr3_dqs_p = 'z;
            assign ddr3_dqs_n = 'z;
        end else if ((DEMO_MODE == DEMO_MODE_DDR_VIDEO)
            || (DEMO_MODE == DEMO_MODE_BIST_ONLY)) begin : g_ddr_mode

            logic ui_clk;
            logic mig_ui_reset;
            logic ui_aresetn;
            logic init_calib_complete;
            logic ddr_clk_locked;
            logic mig_mmcm_locked;
            logic [11:0] device_temp;

            logic boot_bist_start_q;
            logic boot_bist_started_q;
            logic calibration_seen_ui_q;
            logic ddr_fault_sticky_ui_q;

            logic bist_status_busy;
            logic bist_status_done;
            logic bist_status_pass;
            logic bist_status_error;
            logic [2:0] bist_status_pattern;
            logic [6:0] bist_status_walk_bit;
            logic [28:0] bist_status_current_addr;
            logic [2:0] bist_first_error_kind;
            logic [28:0] bist_first_error_addr;
            logic [127:0] bist_first_error_expected;
            logic [127:0] bist_first_error_actual;
            logic [1:0] bist_first_error_resp;

            logic [3:0] wdma_awid;
            logic [28:0] wdma_awaddr;
            logic [7:0] wdma_awlen;
            logic [2:0] wdma_awsize;
            logic [1:0] wdma_awburst;
            logic [0:0] wdma_awlock;
            logic [3:0] wdma_awcache;
            logic [2:0] wdma_awprot;
            logic [3:0] wdma_awqos;
            logic wdma_awvalid;
            logic wdma_awready;
            logic [127:0] wdma_wdata;
            logic [15:0] wdma_wstrb;
            logic wdma_wlast;
            logic wdma_wvalid;
            logic wdma_wready;
            logic [3:0] wdma_bid;
            logic [1:0] wdma_bresp;
            logic wdma_bvalid;
            logic wdma_bready;

            logic [3:0] rdma_arid;
            logic [28:0] rdma_araddr;
            logic [7:0] rdma_arlen;
            logic [2:0] rdma_arsize;
            logic [1:0] rdma_arburst;
            logic [0:0] rdma_arlock;
            logic [3:0] rdma_arcache;
            logic [2:0] rdma_arprot;
            logic [3:0] rdma_arqos;
            logic rdma_arvalid;
            logic rdma_arready;
            logic [3:0] rdma_rid;
            logic [127:0] rdma_rdata;
            logic [1:0] rdma_rresp;
            logic rdma_rlast;
            logic rdma_rvalid;
            logic rdma_rready;

            logic [3:0] bist_awid;
            logic [28:0] bist_awaddr;
            logic [7:0] bist_awlen;
            logic [2:0] bist_awsize;
            logic [1:0] bist_awburst;
            logic [0:0] bist_awlock;
            logic [3:0] bist_awcache;
            logic [2:0] bist_awprot;
            logic [3:0] bist_awqos;
            logic bist_awvalid;
            logic bist_awready;
            logic [127:0] bist_wdata;
            logic [15:0] bist_wstrb;
            logic bist_wlast;
            logic bist_wvalid;
            logic bist_wready;
            logic [3:0] bist_bid;
            logic [1:0] bist_bresp;
            logic bist_bvalid;
            logic bist_bready;
            logic [3:0] bist_arid;
            logic [28:0] bist_araddr;
            logic [7:0] bist_arlen;
            logic [2:0] bist_arsize;
            logic [1:0] bist_arburst;
            logic [0:0] bist_arlock;
            logic [3:0] bist_arcache;
            logic [2:0] bist_arprot;
            logic [3:0] bist_arqos;
            logic bist_arvalid;
            logic bist_arready;
            logic [3:0] bist_rid;
            logic [127:0] bist_rdata;
            logic [1:0] bist_rresp;
            logic bist_rlast;
            logic bist_rvalid;
            logic bist_rready;

            logic [3:0] mig_awid;
            logic [28:0] mig_awaddr;
            logic [7:0] mig_awlen;
            logic [2:0] mig_awsize;
            logic [1:0] mig_awburst;
            logic [0:0] mig_awlock;
            logic [3:0] mig_awcache;
            logic [2:0] mig_awprot;
            logic [3:0] mig_awqos;
            logic mig_awvalid;
            logic mig_awready;
            logic [127:0] mig_wdata;
            logic [15:0] mig_wstrb;
            logic mig_wlast;
            logic mig_wvalid;
            logic mig_wready;
            logic [3:0] mig_bid;
            logic [1:0] mig_bresp;
            logic mig_bvalid;
            logic mig_bready;
            logic [3:0] mig_arid;
            logic [28:0] mig_araddr;
            logic [7:0] mig_arlen;
            logic [2:0] mig_arsize;
            logic [1:0] mig_arburst;
            logic [0:0] mig_arlock;
            logic [3:0] mig_arcache;
            logic [2:0] mig_arprot;
            logic [3:0] mig_arqos;
            logic mig_arvalid;
            logic mig_arready;
            logic [3:0] mig_rid;
            logic [127:0] mig_rdata;
            logic [1:0] mig_rresp;
            logic mig_rlast;
            logic mig_rvalid;
            logic mig_rready;

            // The exported AXI fabric exposes 32-bit address ports, while the
            // selected 512 MiB MIG address space uses 29 address bits. Keep
            // the native module interfaces at 29 bits and adapt only at the
            // generated Block Design boundary.
            logic [31:0] fabric_wdma_awaddr;
            logic [31:0] fabric_rdma_araddr;
            logic [31:0] fabric_bist_awaddr;
            logic [31:0] fabric_bist_araddr;
            logic [31:0] fabric_mig_awaddr;
            logic [31:0] fabric_mig_araddr;

            logic framebuffer_status_fault;

            assign ui_aresetn = !mig_ui_reset;
            assign bist_done_ui = bist_status_done;
            assign bist_pass_ui = bist_status_pass;
            assign ddr_fault_ui = ddr_fault_sticky_ui_q;

            assign fabric_wdma_awaddr = {3'b000, wdma_awaddr};
            assign fabric_rdma_araddr = {3'b000, rdma_araddr};
            assign fabric_bist_awaddr = {3'b000, bist_awaddr};
            assign fabric_bist_araddr = {3'b000, bist_araddr};
            assign mig_awaddr = fabric_mig_awaddr[28:0];
            assign mig_araddr = fabric_mig_araddr[28:0];

            initial begin
                calibration_seen_ui_q = 1'b0;
                ddr_fault_sticky_ui_q = 1'b0;
            end

            // Generate one clean start pulse after each successful MIG reset
            // release. A calibration loss resets the BIST and causes a full
            // destructive retest before video can resume.
            always_ff @(posedge ui_clk) begin
                if (mig_ui_reset) begin
                    boot_bist_start_q <= 1'b0;
                    boot_bist_started_q <= 1'b0;
                end else begin
                    boot_bist_start_q <= !boot_bist_started_q;
                    if (!boot_bist_started_q) begin
                        boot_bist_started_q <= 1'b1;
                    end
                end

                if (init_calib_complete) begin
                    calibration_seen_ui_q <= 1'b1;
                end

                if ((calibration_seen_ui_q && !init_calib_complete)
                    || (bist_status_done && !bist_status_pass)
                    || bist_status_error
                    || framebuffer_status_fault) begin
                    ddr_fault_sticky_ui_q <= 1'b1;
                end
            end

            ddr3_mig_wrapper u_ddr3_mig_wrapper (
                .clk_50m(clk_50m_global),
                .reset_async(1'b0),

                .ddr3_addr,
                .ddr3_ba,
                .ddr3_ras_n,
                .ddr3_cas_n,
                .ddr3_we_n,
                .ddr3_reset_n,
                .ddr3_ck_p,
                .ddr3_ck_n,
                .ddr3_cke,
                .ddr3_dm,
                .ddr3_odt,
                .ddr3_dq,
                .ddr3_dqs_p,
                .ddr3_dqs_n,

                .ui_clk,
                .ui_reset(mig_ui_reset),
                .init_calib_complete,
                .ddr_clk_locked,
                .mig_mmcm_locked,
                .device_temp,

                .s_axi_awid(mig_awid),
                .s_axi_awaddr(mig_awaddr),
                .s_axi_awlen(mig_awlen),
                .s_axi_awsize(mig_awsize),
                .s_axi_awburst(mig_awburst),
                .s_axi_awlock(mig_awlock),
                .s_axi_awcache(mig_awcache),
                .s_axi_awprot(mig_awprot),
                .s_axi_awqos(mig_awqos),
                .s_axi_awvalid(mig_awvalid),
                .s_axi_awready(mig_awready),
                .s_axi_wdata(mig_wdata),
                .s_axi_wstrb(mig_wstrb),
                .s_axi_wlast(mig_wlast),
                .s_axi_wvalid(mig_wvalid),
                .s_axi_wready(mig_wready),
                .s_axi_bid(mig_bid),
                .s_axi_bresp(mig_bresp),
                .s_axi_bvalid(mig_bvalid),
                .s_axi_bready(mig_bready),
                .s_axi_arid(mig_arid),
                .s_axi_araddr(mig_araddr),
                .s_axi_arlen(mig_arlen),
                .s_axi_arsize(mig_arsize),
                .s_axi_arburst(mig_arburst),
                .s_axi_arlock(mig_arlock),
                .s_axi_arcache(mig_arcache),
                .s_axi_arprot(mig_arprot),
                .s_axi_arqos(mig_arqos),
                .s_axi_arvalid(mig_arvalid),
                .s_axi_arready(mig_arready),
                .s_axi_rid(mig_rid),
                .s_axi_rdata(mig_rdata),
                .s_axi_rresp(mig_rresp),
                .s_axi_rlast(mig_rlast),
                .s_axi_rvalid(mig_rvalid),
                .s_axi_rready(mig_rready)
            );

            ddr3_bist u_ddr3_bist (
                .ui_clk,
                .ui_reset(mig_ui_reset),
                .start(boot_bist_start_q),
                .status_busy(bist_status_busy),
                .status_done(bist_status_done),
                .status_pass(bist_status_pass),
                .status_error(bist_status_error),
                .status_pattern(bist_status_pattern),
                .status_walk_bit(bist_status_walk_bit),
                .status_current_addr(bist_status_current_addr),
                .first_error_kind(bist_first_error_kind),
                .first_error_addr(bist_first_error_addr),
                .first_error_expected(bist_first_error_expected),
                .first_error_actual(bist_first_error_actual),
                .first_error_resp(bist_first_error_resp),
                .m_axi_awid(bist_awid),
                .m_axi_awaddr(bist_awaddr),
                .m_axi_awlen(bist_awlen),
                .m_axi_awsize(bist_awsize),
                .m_axi_awburst(bist_awburst),
                .m_axi_awlock(bist_awlock),
                .m_axi_awcache(bist_awcache),
                .m_axi_awprot(bist_awprot),
                .m_axi_awqos(bist_awqos),
                .m_axi_awvalid(bist_awvalid),
                .m_axi_awready(bist_awready),
                .m_axi_wdata(bist_wdata),
                .m_axi_wstrb(bist_wstrb),
                .m_axi_wlast(bist_wlast),
                .m_axi_wvalid(bist_wvalid),
                .m_axi_wready(bist_wready),
                .m_axi_bid(bist_bid),
                .m_axi_bresp(bist_bresp),
                .m_axi_bvalid(bist_bvalid),
                .m_axi_bready(bist_bready),
                .m_axi_arid(bist_arid),
                .m_axi_araddr(bist_araddr),
                .m_axi_arlen(bist_arlen),
                .m_axi_arsize(bist_arsize),
                .m_axi_arburst(bist_arburst),
                .m_axi_arlock(bist_arlock),
                .m_axi_arcache(bist_arcache),
                .m_axi_arprot(bist_arprot),
                .m_axi_arqos(bist_arqos),
                .m_axi_arvalid(bist_arvalid),
                .m_axi_arready(bist_arready),
                .m_axi_rid(bist_rid),
                .m_axi_rdata(bist_rdata),
                .m_axi_rresp(bist_rresp),
                .m_axi_rlast(bist_rlast),
                .m_axi_rvalid(bist_rvalid),
                .m_axi_rready(bist_rready)
            );

            if (DEMO_MODE == DEMO_MODE_DDR_VIDEO) begin : g_framebuffer_video
                logic framebuffer_ui_reset;
                logic framebuffer_pix_reset;
                logic [23:0] framebuffer_tdata;
                logic framebuffer_tvalid;
                logic framebuffer_tready;
                logic framebuffer_tuser;
                logic framebuffer_tlast;
                logic framebuffer_display_valid_pix;

                logic perf_measurement_active;
                logic perf_measurement_valid;
                logic perf_bandwidth_pass;
                logic [31:0] perf_window_cycles;
                logic [31:0] perf_write_beats;
                logic [31:0] perf_read_beats;
                logic [31:0] perf_write_stall_cycles;
                logic [31:0] perf_read_stall_cycles;
                logic [31:0] perf_measurement_count;
                logic perf_swap_interval_valid;
                logic [31:0] perf_swap_interval_cycles;
                logic [31:0] perf_swap_count;
                logic [31:0] perf_repeat_count;

                // One named probe keeps the optional Tcl-inserted ILA simple
                // and gives the capture an immutable bit layout:
                // [291:260] repeat_count, [259:228] swap_count,
                // [227:196] swap_interval_cycles,
                // [195:164] measurement_count,
                // [163:132] read_stall_cycles,
                // [131:100] write_stall_cycles, [99:68] read_beats,
                // [67:36] write_beats, [35:4] window_cycles,
                // [3] interval_valid, [2] active, [1] pass, [0] valid.
                (* KEEP = "TRUE", MARK_DEBUG = "TRUE" *)
                logic [291:0] framebuffer_perf_debug_bus;
                (* KEEP = "TRUE" *)
                logic framebuffer_perf_ui_clk;

                assign framebuffer_perf_ui_clk = ui_clk;
                assign framebuffer_perf_debug_bus = {
                    perf_repeat_count,
                    perf_swap_count,
                    perf_swap_interval_cycles,
                    perf_measurement_count,
                    perf_read_stall_cycles,
                    perf_write_stall_cycles,
                    perf_read_beats,
                    perf_write_beats,
                    perf_window_cycles,
                    perf_swap_interval_valid,
                    perf_measurement_active,
                    perf_bandwidth_pass,
                    perf_measurement_valid
                };
                // MIG reset and BIST status are native to ui_clk.  Keep the
                // framebuffer reset synchronous in that domain and add four
                // clean release cycles after the boot qualification passes.
                // This avoids using UI-domain logic as an asynchronous reset
                // source and keeps every functional reset transition on a
                // destination-domain edge.
                // bist_pass_sync2_q is the reviewed two-flop UI-to-pixel
                // level crossing at the board boundary.  In particular,
                // bist_status_pass must never feed an asynchronous PRE/CLR in
                // the pixel domain: that topology was a CDC-10 critical
                // finding in the diagnostic implementation.
                sync_reset_release u_framebuffer_ui_reset_release (
                    .clk(ui_clk),
                    .reset_request(mig_ui_reset || !bist_status_pass),
                    .reset_out(framebuffer_ui_reset)
                );

                sync_reset_release u_framebuffer_pix_reset_release (
                    .clk(pix_clk),
                    .reset_request(pix_reset || !bist_pass_sync2_q),
                    .reset_out(framebuffer_pix_reset)
                );

                assign core_input_tdata = framebuffer_tdata;
                assign core_input_tvalid = framebuffer_tvalid;
                assign framebuffer_tready = core_input_tready;
                assign core_input_tuser = framebuffer_tuser;
                assign core_input_tlast = framebuffer_tlast;

                framebuffer_subsystem #(
                    .ENABLE_PERF_MONITOR(ENABLE_PERF_MONITOR)
                ) u_framebuffer_subsystem (
                    .pix_clk,
                    .pix_reset(framebuffer_pix_reset),
                    .vblank_start,
                    .s_axis_tdata(pattern_tdata),
                    .s_axis_tvalid(pattern_tvalid),
                    .s_axis_tready(pattern_tready),
                    .s_axis_tuser(pattern_tuser),
                    .s_axis_tlast(pattern_tlast),
                    .m_axis_tdata(framebuffer_tdata),
                    .m_axis_tvalid(framebuffer_tvalid),
                    .m_axis_tready(framebuffer_tready),
                    .m_axis_tuser(framebuffer_tuser),
                    .m_axis_tlast(framebuffer_tlast),
                    .display_valid_pix(framebuffer_display_valid_pix),
                    .ui_clk,
                    .ui_reset(framebuffer_ui_reset),
                    .m_axi_wdma_awid(wdma_awid),
                    .m_axi_wdma_awaddr(wdma_awaddr),
                    .m_axi_wdma_awlen(wdma_awlen),
                    .m_axi_wdma_awsize(wdma_awsize),
                    .m_axi_wdma_awburst(wdma_awburst),
                    .m_axi_wdma_awlock(wdma_awlock),
                    .m_axi_wdma_awcache(wdma_awcache),
                    .m_axi_wdma_awprot(wdma_awprot),
                    .m_axi_wdma_awqos(wdma_awqos),
                    .m_axi_wdma_awvalid(wdma_awvalid),
                    .m_axi_wdma_awready(wdma_awready),
                    .m_axi_wdma_wdata(wdma_wdata),
                    .m_axi_wdma_wstrb(wdma_wstrb),
                    .m_axi_wdma_wlast(wdma_wlast),
                    .m_axi_wdma_wvalid(wdma_wvalid),
                    .m_axi_wdma_wready(wdma_wready),
                    .m_axi_wdma_bid(wdma_bid),
                    .m_axi_wdma_bresp(wdma_bresp),
                    .m_axi_wdma_bvalid(wdma_bvalid),
                    .m_axi_wdma_bready(wdma_bready),
                    .m_axi_rdma_arid(rdma_arid),
                    .m_axi_rdma_araddr(rdma_araddr),
                    .m_axi_rdma_arlen(rdma_arlen),
                    .m_axi_rdma_arsize(rdma_arsize),
                    .m_axi_rdma_arburst(rdma_arburst),
                    .m_axi_rdma_arlock(rdma_arlock),
                    .m_axi_rdma_arcache(rdma_arcache),
                    .m_axi_rdma_arprot(rdma_arprot),
                    .m_axi_rdma_arqos(rdma_arqos),
                    .m_axi_rdma_arvalid(rdma_arvalid),
                    .m_axi_rdma_arready(rdma_arready),
                    .m_axi_rdma_rid(rdma_rid),
                    .m_axi_rdma_rdata(rdma_rdata),
                    .m_axi_rdma_rresp(rdma_rresp),
                    .m_axi_rdma_rlast(rdma_rlast),
                    .m_axi_rdma_rvalid(rdma_rvalid),
                    .m_axi_rdma_rready(rdma_rready),
                    .status_write_busy(),
                    .status_write_frame_done(),
                    .status_write_frame_success(),
                    .status_read_busy(),
                    .status_read_fetch_done(),
                    .status_read_fetch_success(),
                    .status_read_frame_done(),
                    .status_read_frame_success(),
                    .status_display_valid(),
                    .status_swap(),
                    .status_repeat_frame(),
                    .status_fault(framebuffer_status_fault),
                    .front_buffer_index(),
                    .back_buffer_index(),
                    .slot0_state(),
                    .slot1_state(),
                    .debug_measurement_active(perf_measurement_active),
                    .debug_measurement_valid(perf_measurement_valid),
                    .debug_bandwidth_pass(perf_bandwidth_pass),
                    .debug_window_cycles(perf_window_cycles),
                    .debug_write_beats(perf_write_beats),
                    .debug_read_beats(perf_read_beats),
                    .debug_write_stall_cycles(perf_write_stall_cycles),
                    .debug_read_stall_cycles(perf_read_stall_cycles),
                    .debug_measurement_count(perf_measurement_count),
                    .debug_swap_interval_valid(perf_swap_interval_valid),
                    .debug_swap_interval_cycles(perf_swap_interval_cycles),
                    .debug_swap_count(perf_swap_count),
                    .debug_repeat_count(perf_repeat_count)
                );
            end else begin : g_bist_only
                assign core_input_tdata = '0;
                assign core_input_tvalid = 1'b0;
                assign core_input_tuser = 1'b0;
                assign core_input_tlast = 1'b0;
                assign pattern_tready = 1'b0;
                assign framebuffer_status_fault = 1'b0;

                assign wdma_awid = '0;
                assign wdma_awaddr = '0;
                assign wdma_awlen = '0;
                assign wdma_awsize = '0;
                assign wdma_awburst = '0;
                assign wdma_awlock = '0;
                assign wdma_awcache = '0;
                assign wdma_awprot = '0;
                assign wdma_awqos = '0;
                assign wdma_awvalid = 1'b0;
                assign wdma_wdata = '0;
                assign wdma_wstrb = '0;
                assign wdma_wlast = 1'b0;
                assign wdma_wvalid = 1'b0;
                assign wdma_bready = 1'b0;

                assign rdma_arid = '0;
                assign rdma_araddr = '0;
                assign rdma_arlen = '0;
                assign rdma_arsize = '0;
                assign rdma_arburst = '0;
                assign rdma_arlock = '0;
                assign rdma_arcache = '0;
                assign rdma_arprot = '0;
                assign rdma_arqos = '0;
                assign rdma_arvalid = 1'b0;
                assign rdma_rready = 1'b0;
            end

            // The generated Vivado wrapper is intentionally not checked into
            // rtl/. Add axi_ddr_fabric_wrapper.v (or the BD that generates it)
            // to the Vivado project before elaborating DEMO_MODE 1 or 2.
            axi_ddr_fabric_wrapper u_axi_ddr_fabric_wrapper (
                .M00_AXI_MIG_araddr(fabric_mig_araddr),
                .M00_AXI_MIG_arburst(mig_arburst),
                .M00_AXI_MIG_arcache(mig_arcache),
                .M00_AXI_MIG_arid(mig_arid),
                .M00_AXI_MIG_arlen(mig_arlen),
                .M00_AXI_MIG_arlock(mig_arlock),
                .M00_AXI_MIG_arprot(mig_arprot),
                .M00_AXI_MIG_arqos(mig_arqos),
                .M00_AXI_MIG_arready(mig_arready),
                .M00_AXI_MIG_arregion(),
                .M00_AXI_MIG_arsize(mig_arsize),
                .M00_AXI_MIG_arvalid(mig_arvalid),
                .M00_AXI_MIG_awaddr(fabric_mig_awaddr),
                .M00_AXI_MIG_awburst(mig_awburst),
                .M00_AXI_MIG_awcache(mig_awcache),
                .M00_AXI_MIG_awid(mig_awid),
                .M00_AXI_MIG_awlen(mig_awlen),
                .M00_AXI_MIG_awlock(mig_awlock),
                .M00_AXI_MIG_awprot(mig_awprot),
                .M00_AXI_MIG_awqos(mig_awqos),
                .M00_AXI_MIG_awready(mig_awready),
                .M00_AXI_MIG_awregion(),
                .M00_AXI_MIG_awsize(mig_awsize),
                .M00_AXI_MIG_awvalid(mig_awvalid),
                .M00_AXI_MIG_bid(mig_bid),
                .M00_AXI_MIG_bready(mig_bready),
                .M00_AXI_MIG_bresp(mig_bresp),
                .M00_AXI_MIG_bvalid(mig_bvalid),
                .M00_AXI_MIG_rdata(mig_rdata),
                .M00_AXI_MIG_rid(mig_rid),
                .M00_AXI_MIG_rlast(mig_rlast),
                .M00_AXI_MIG_rready(mig_rready),
                .M00_AXI_MIG_rresp(mig_rresp),
                .M00_AXI_MIG_rvalid(mig_rvalid),
                .M00_AXI_MIG_wdata(mig_wdata),
                .M00_AXI_MIG_wlast(mig_wlast),
                .M00_AXI_MIG_wready(mig_wready),
                .M00_AXI_MIG_wstrb(mig_wstrb),
                .M00_AXI_MIG_wvalid(mig_wvalid),

                .S00_AXI_WDMA_araddr('0),
                .S00_AXI_WDMA_arburst('0),
                .S00_AXI_WDMA_arcache('0),
                .S00_AXI_WDMA_arid('0),
                .S00_AXI_WDMA_arlen('0),
                .S00_AXI_WDMA_arlock('0),
                .S00_AXI_WDMA_arprot('0),
                .S00_AXI_WDMA_arqos('0),
                .S00_AXI_WDMA_arready(),
                .S00_AXI_WDMA_arsize('0),
                .S00_AXI_WDMA_arvalid(1'b0),
                .S00_AXI_WDMA_awaddr(fabric_wdma_awaddr),
                .S00_AXI_WDMA_awburst(wdma_awburst),
                .S00_AXI_WDMA_awcache(wdma_awcache),
                .S00_AXI_WDMA_awid(wdma_awid),
                .S00_AXI_WDMA_awlen(wdma_awlen),
                .S00_AXI_WDMA_awlock(wdma_awlock),
                .S00_AXI_WDMA_awprot(wdma_awprot),
                .S00_AXI_WDMA_awqos(wdma_awqos),
                .S00_AXI_WDMA_awready(wdma_awready),
                .S00_AXI_WDMA_awsize(wdma_awsize),
                .S00_AXI_WDMA_awvalid(wdma_awvalid),
                .S00_AXI_WDMA_bid(wdma_bid),
                .S00_AXI_WDMA_bready(wdma_bready),
                .S00_AXI_WDMA_bresp(wdma_bresp),
                .S00_AXI_WDMA_bvalid(wdma_bvalid),
                .S00_AXI_WDMA_rdata(),
                .S00_AXI_WDMA_rid(),
                .S00_AXI_WDMA_rlast(),
                .S00_AXI_WDMA_rready(1'b0),
                .S00_AXI_WDMA_rresp(),
                .S00_AXI_WDMA_rvalid(),
                .S00_AXI_WDMA_wdata(wdma_wdata),
                .S00_AXI_WDMA_wlast(wdma_wlast),
                .S00_AXI_WDMA_wready(wdma_wready),
                .S00_AXI_WDMA_wstrb(wdma_wstrb),
                .S00_AXI_WDMA_wvalid(wdma_wvalid),

                .S01_AXI_RDMA_araddr(fabric_rdma_araddr),
                .S01_AXI_RDMA_arburst(rdma_arburst),
                .S01_AXI_RDMA_arcache(rdma_arcache),
                .S01_AXI_RDMA_arid(rdma_arid),
                .S01_AXI_RDMA_arlen(rdma_arlen),
                .S01_AXI_RDMA_arlock(rdma_arlock),
                .S01_AXI_RDMA_arprot(rdma_arprot),
                .S01_AXI_RDMA_arqos(rdma_arqos),
                .S01_AXI_RDMA_arready(rdma_arready),
                .S01_AXI_RDMA_arsize(rdma_arsize),
                .S01_AXI_RDMA_arvalid(rdma_arvalid),
                .S01_AXI_RDMA_awaddr('0),
                .S01_AXI_RDMA_awburst('0),
                .S01_AXI_RDMA_awcache('0),
                .S01_AXI_RDMA_awid('0),
                .S01_AXI_RDMA_awlen('0),
                .S01_AXI_RDMA_awlock('0),
                .S01_AXI_RDMA_awprot('0),
                .S01_AXI_RDMA_awqos('0),
                .S01_AXI_RDMA_awready(),
                .S01_AXI_RDMA_awsize('0),
                .S01_AXI_RDMA_awvalid(1'b0),
                .S01_AXI_RDMA_bid(),
                .S01_AXI_RDMA_bready(1'b0),
                .S01_AXI_RDMA_bresp(),
                .S01_AXI_RDMA_bvalid(),
                .S01_AXI_RDMA_rdata(rdma_rdata),
                .S01_AXI_RDMA_rid(rdma_rid),
                .S01_AXI_RDMA_rlast(rdma_rlast),
                .S01_AXI_RDMA_rready(rdma_rready),
                .S01_AXI_RDMA_rresp(rdma_rresp),
                .S01_AXI_RDMA_rvalid(rdma_rvalid),
                .S01_AXI_RDMA_wdata('0),
                .S01_AXI_RDMA_wlast(1'b0),
                .S01_AXI_RDMA_wready(),
                .S01_AXI_RDMA_wstrb('0),
                .S01_AXI_RDMA_wvalid(1'b0),

                .S02_AXI_BIST_araddr(fabric_bist_araddr),
                .S02_AXI_BIST_arburst(bist_arburst),
                .S02_AXI_BIST_arcache(bist_arcache),
                .S02_AXI_BIST_arid(bist_arid),
                .S02_AXI_BIST_arlen(bist_arlen),
                .S02_AXI_BIST_arlock(bist_arlock),
                .S02_AXI_BIST_arprot(bist_arprot),
                .S02_AXI_BIST_arqos(bist_arqos),
                .S02_AXI_BIST_arready(bist_arready),
                .S02_AXI_BIST_arsize(bist_arsize),
                .S02_AXI_BIST_arvalid(bist_arvalid),
                .S02_AXI_BIST_awaddr(fabric_bist_awaddr),
                .S02_AXI_BIST_awburst(bist_awburst),
                .S02_AXI_BIST_awcache(bist_awcache),
                .S02_AXI_BIST_awid(bist_awid),
                .S02_AXI_BIST_awlen(bist_awlen),
                .S02_AXI_BIST_awlock(bist_awlock),
                .S02_AXI_BIST_awprot(bist_awprot),
                .S02_AXI_BIST_awqos(bist_awqos),
                .S02_AXI_BIST_awready(bist_awready),
                .S02_AXI_BIST_awsize(bist_awsize),
                .S02_AXI_BIST_awvalid(bist_awvalid),
                .S02_AXI_BIST_bid(bist_bid),
                .S02_AXI_BIST_bready(bist_bready),
                .S02_AXI_BIST_bresp(bist_bresp),
                .S02_AXI_BIST_bvalid(bist_bvalid),
                .S02_AXI_BIST_rdata(bist_rdata),
                .S02_AXI_BIST_rid(bist_rid),
                .S02_AXI_BIST_rlast(bist_rlast),
                .S02_AXI_BIST_rready(bist_rready),
                .S02_AXI_BIST_rresp(bist_rresp),
                .S02_AXI_BIST_rvalid(bist_rvalid),
                .S02_AXI_BIST_wdata(bist_wdata),
                .S02_AXI_BIST_wlast(bist_wlast),
                .S02_AXI_BIST_wready(bist_wready),
                .S02_AXI_BIST_wstrb(bist_wstrb),
                .S02_AXI_BIST_wvalid(bist_wvalid),
                .ui_aresetn,
                .ui_clk
            );
        end else begin : g_invalid_mode
            assign core_input_tdata = '0;
            assign core_input_tvalid = 1'b0;
            assign core_input_tuser = 1'b0;
            assign core_input_tlast = 1'b0;
            assign pattern_tready = 1'b0;
            assign ddr_fault_ui = 1'b1;
            assign bist_done_ui = 1'b0;
            assign bist_pass_ui = 1'b0;
            assign ddr3_addr = '0;
            assign ddr3_ba = '0;
            assign ddr3_ras_n = 1'b1;
            assign ddr3_cas_n = 1'b1;
            assign ddr3_we_n = 1'b1;
            assign ddr3_reset_n = 1'b0;
            assign ddr3_ck_p = '0;
            assign ddr3_ck_n = '0;
            assign ddr3_cke = '0;
            assign ddr3_dm = '0;
            assign ddr3_odt = '0;
            assign ddr3_dq = 'z;
            assign ddr3_dqs_p = 'z;
            assign ddr3_dqs_n = 'z;
        end
    endgenerate

endmodule
