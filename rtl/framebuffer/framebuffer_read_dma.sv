// Fixed-geometry AXI4 to AXI4-Stream framebuffer reader.
//
// One controller command owns one complete frame. The UI-domain engine issues
// exactly one AXI read burst at a time and writes XRGB8888 beats into a
// dual-clock FIFO. After a fixed prefetch threshold, the pixel-domain engine
// unpacks four RGB888 pixels per beat and regenerates SOF/EOL from geometry.

module framebuffer_read_dma #(
    parameter integer FRAME_WIDTH = framebuffer_pkg::FRAME_WIDTH,
    parameter integer FRAME_HEIGHT = framebuffer_pkg::FRAME_HEIGHT,
    parameter integer STRIDE_BYTES = framebuffer_pkg::STRIDE_BYTES,
    parameter logic [28:0] FB0_BASE_ADDR = 29'(framebuffer_pkg::FB0_BASE_ADDR),
    parameter logic [28:0] FB1_BASE_ADDR = 29'(framebuffer_pkg::FB1_BASE_ADDR),
    parameter integer FB_SLOT_BYTES = framebuffer_pkg::FB_SLOT_BYTES,
    parameter integer BURST_BEATS = framebuffer_pkg::DMA_BURST_BEATS,
    parameter integer FIFO_DEPTH = 512,
    parameter integer START_THRESHOLD_BEATS = 256,
    parameter logic [3:0] AXI_ID = 4'h2
) (
    // Pixel-domain AXI4-Stream Video output.
    input logic pix_clk,
    input logic pix_reset,
    output logic [23:0] m_axis_tdata,
    output logic m_axis_tvalid,
    input logic m_axis_tready,
    output logic m_axis_tuser,
    output logic m_axis_tlast,

    // UI-domain command from framebuffer_control.
    input logic ui_clk,
    input logic ui_reset,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic cmd_buffer_index,

    output logic status_busy,
    output logic status_fetch_done,
    output logic status_fetch_success,
    output logic status_frame_done,
    output logic status_frame_success,
    output logic status_axi_error,
    output logic status_protocol_error,

    // Sticky first-error telemetry. Kind: 0 none, 1 RRESP, 2 RID, 3 RLAST.
    output logic [1:0] first_error_kind,
    output logic [28:0] first_error_addr,
    output logic [1:0] first_error_resp,

    // AXI4 read master. The MIG/interconnect contract is fixed at
    // 29-bit byte addresses, 128-bit data, and 4-bit IDs.
    output logic [3:0] m_axi_arid,
    output logic [28:0] m_axi_araddr,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic [0:0] m_axi_arlock,
    output logic [3:0] m_axi_arcache,
    output logic [2:0] m_axi_arprot,
    output logic [3:0] m_axi_arqos,
    output logic m_axi_arvalid,
    input logic m_axi_arready,

    input logic [3:0] m_axi_rid,
    input logic [127:0] m_axi_rdata,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rlast,
    input logic m_axi_rvalid,
    output logic m_axi_rready
);

    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam integer FRAME_BEATS =
        FRAME_PIXELS / framebuffer_pkg::PIXELS_PER_AXI_BEAT;
    localparam integer X_COUNT_WIDTH =
        (FRAME_WIDTH <= 1) ? 1 : $clog2(FRAME_WIDTH);
    localparam integer Y_COUNT_WIDTH =
        (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT);

    localparam logic [X_COUNT_WIDTH-1:0] LAST_X =
        X_COUNT_WIDTH'(FRAME_WIDTH - 1);
    localparam logic [Y_COUNT_WIDTH-1:0] LAST_Y =
        Y_COUNT_WIDTH'(FRAME_HEIGHT - 1);
    localparam logic [31:0] FRAME_BEATS_VALUE = 32'(FRAME_BEATS);
    localparam logic [29:0] FRAME_BYTES_VALUE =
        30'(FRAME_HEIGHT * STRIDE_BYTES);
    localparam logic [29:0] FB0_END_ADDR =
        {1'b0, FB0_BASE_ADDR} + 30'(FB_SLOT_BYTES);
    localparam logic [29:0] FB1_END_ADDR =
        {1'b0, FB1_BASE_ADDR} + 30'(FB_SLOT_BYTES);
    localparam logic [29:0] MIG_END_ADDR = 30'h2000_0000;

    localparam logic [1:0] ERROR_NONE = 2'd0;
    localparam logic [1:0] ERROR_RRESP = 2'd1;
    localparam logic [1:0] ERROR_RID = 2'd2;
    localparam logic [1:0] ERROR_RLAST = 2'd3;

    typedef enum logic [1:0] {
        UI_IDLE,
        UI_ISSUE_ADDRESS,
        UI_RECEIVE_DATA,
        UI_WAIT_CONSUME
    } ui_state_t;

    typedef enum logic {
        PIX_WAIT_START,
        PIX_STREAM_FRAME
    } pixel_state_t;

    ui_state_t ui_state_q;
    pixel_state_t pixel_state_q;

    logic [28:0] current_addr_q;
    logic [31:0] remaining_beats_q;
    logic [8:0] burst_target_beats_q;
    logic [7:0] read_beat_q;
    logic [31:0] fetched_beats_q;
    logic frame_error_q;

    logic [12:0] active_burst_bytes;
    logic [28:0] next_addr;
    logic [31:0] remaining_beats_after_burst;
    logic [8:0] next_burst_target_beats;
    logic [28:0] response_addr;

    logic command_accept;
    logic [28:0] command_base_addr;
    logic ar_transfer;
    logic read_transfer;
    logic expected_rlast;
    logic rresp_error;
    logic rid_error;
    logic rlast_error;
    logic response_error_event;
    logic expected_burst_last_transfer;
    logic expected_frame_last_transfer;
    logic start_threshold_reached;

    logic [127:0] fifo_s_data;
    logic fifo_s_valid;
    logic fifo_s_ready;
    logic [127:0] fifo_m_data;
    logic fifo_m_valid;
    logic fifo_m_ready;

    logic start_toggle_ui_q;
    logic start_sent_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic start_toggle_sync1_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic start_toggle_sync2_q;
    logic start_toggle_seen_q;

    logic consumed_toggle_pix_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic consumed_toggle_sync1_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic consumed_toggle_sync2_q;
    logic consumed_toggle_seen_q;

    logic [1:0] pixel_lane_q;
    logic [X_COUNT_WIDTH-1:0] pixel_x_q;
    logic [Y_COUNT_WIDTH-1:0] pixel_y_q;
    logic [23:0] selected_rgb;
    logic pixel_transfer;
    logic frame_last_pixel;

    function automatic logic [8:0] burst_beats_at(
        input logic [7:0] page_beat_offset,
        input logic [31:0] beats_remaining
    );
        logic [8:0] boundary_beats;
        logic [8:0] selected_beats;
        begin
            boundary_beats = 9'd256 - {1'b0, page_beat_offset};
            selected_beats = 9'(BURST_BEATS);

            if (beats_remaining < {23'd0, selected_beats}) begin
                selected_beats = beats_remaining[8:0];
            end
            if (boundary_beats < selected_beats) begin
                selected_beats = boundary_beats;
            end
            burst_beats_at = selected_beats;
        end
    endfunction

    initial begin
        assert (FRAME_WIDTH >= framebuffer_pkg::PIXELS_PER_AXI_BEAT)
            else $fatal(1, "framebuffer_read_dma FRAME_WIDTH is too small");
        assert (FRAME_HEIGHT >= 1)
            else $fatal(1, "framebuffer_read_dma FRAME_HEIGHT must be positive");
        assert ((FRAME_WIDTH % framebuffer_pkg::PIXELS_PER_AXI_BEAT) == 0)
            else $fatal(1, "framebuffer_read_dma lines must contain whole AXI beats");
        assert (STRIDE_BYTES
            == (FRAME_WIDTH * framebuffer_pkg::BYTES_PER_PIXEL))
            else $fatal(1, "framebuffer_read_dma baseline does not permit line padding");
        assert (FRAME_BYTES_VALUE <= 30'(FB_SLOT_BYTES))
            else $fatal(1, "framebuffer_read_dma frame exceeds one slot");
        assert ((FB0_BASE_ADDR[11:0] == 12'b0)
            && (FB1_BASE_ADDR[11:0] == 12'b0))
            else $fatal(1, "framebuffer_read_dma slot bases must be 4-KiB aligned");
        assert ((FB0_END_ADDR <= {1'b0, FB1_BASE_ADDR})
            && (FB1_END_ADDR <= MIG_END_ADDR))
            else $fatal(1, "framebuffer_read_dma slots overlap or exceed MIG memory");
        assert ((BURST_BEATS >= 1) && (BURST_BEATS <= 256))
            else $fatal(1, "framebuffer_read_dma BURST_BEATS must be in 1..256");
        assert ((FIFO_DEPTH >= 4)
            && ((FIFO_DEPTH & (FIFO_DEPTH - 1)) == 0))
            else $fatal(1, "framebuffer_read_dma FIFO_DEPTH must be a power of two >= 4");
        assert ((START_THRESHOLD_BEATS >= 1)
            && (START_THRESHOLD_BEATS <= FIFO_DEPTH)
            && (START_THRESHOLD_BEATS <= FRAME_BEATS))
            else $fatal(1, "framebuffer_read_dma start threshold is invalid");
    end

    assign command_base_addr = cmd_buffer_index
        ? FB1_BASE_ADDR : FB0_BASE_ADDR;
    assign cmd_ready = !ui_reset && (ui_state_q == UI_IDLE);
    assign command_accept = cmd_valid && cmd_ready;

    assign active_burst_bytes = {burst_target_beats_q, 4'b0000};
    assign next_addr = current_addr_q
        + {{16{1'b0}}, active_burst_bytes};
    assign remaining_beats_after_burst = remaining_beats_q
        - {23'd0, burst_target_beats_q};
    assign next_burst_target_beats = burst_beats_at(
        next_addr[11:4],
        remaining_beats_after_burst
    );
    assign response_addr = current_addr_q
        + {{17{1'b0}}, read_beat_q, 4'b0000};

    assign m_axi_arid = AXI_ID;
    assign m_axi_araddr = current_addr_q;
    assign m_axi_arlen = burst_target_beats_q[7:0] - 8'd1;
    assign m_axi_arsize = framebuffer_pkg::AXI_BEAT_SIZE;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arlock = 1'b0;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_arprot = 3'b000;
    assign m_axi_arqos = 4'b0000;
    assign m_axi_arvalid = ui_state_q == UI_ISSUE_ADDRESS;
    assign ar_transfer = m_axi_arvalid && m_axi_arready;

    assign expected_rlast = ({1'b0, read_beat_q} + 9'd1)
        == burst_target_beats_q;
    assign rresp_error = m_axi_rresp != 2'b00;
    assign rid_error = m_axi_rid != AXI_ID;
    assign rlast_error = m_axi_rlast != expected_rlast;
    assign response_error_event = rresp_error || rid_error || rlast_error;

    assign fifo_s_valid = (ui_state_q == UI_RECEIVE_DATA) && m_axi_rvalid;
    // Preserve the fixed frame length after an AXI response fault so neither
    // clock domain deadlocks. The failed 128-bit word is replaced by black;
    // frame_success remains low, preventing controller-side promotion.
    assign fifo_s_data = response_error_event
        ? {128{1'b0}} : m_axi_rdata;
    assign m_axi_rready = (ui_state_q == UI_RECEIVE_DATA) && fifo_s_ready;
    assign read_transfer = m_axi_rvalid && m_axi_rready;
    assign expected_burst_last_transfer = read_transfer && expected_rlast;
    assign expected_frame_last_transfer = expected_burst_last_transfer
        && (remaining_beats_q == {23'd0, burst_target_beats_q});
    assign start_threshold_reached =
        ((fetched_beats_q + 32'd1) >= 32'(START_THRESHOLD_BEATS))
        || expected_frame_last_transfer;

    axis_async_fifo #(
        .DATA_WIDTH(framebuffer_pkg::AXI_DATA_WIDTH),
        .DEPTH(FIFO_DEPTH)
    ) u_ui_to_pixel_fifo (
        .s_axis_aclk(ui_clk),
        .s_axis_aresetn(!ui_reset),
        .s_axis_tdata(fifo_s_data),
        .s_axis_tvalid(fifo_s_valid),
        .s_axis_tready(fifo_s_ready),
        .m_axis_aclk(pix_clk),
        .m_axis_aresetn(!pix_reset),
        .m_axis_tdata(fifo_m_data),
        .m_axis_tvalid(fifo_m_valid),
        .m_axis_tready(fifo_m_ready)
    );

    // Synchronize final-pixel retirement back into the UI clock domain.
    always_ff @(posedge ui_clk) begin
        if (ui_reset) begin
            consumed_toggle_sync1_q <= 1'b0;
            consumed_toggle_sync2_q <= 1'b0;
        end else begin
            consumed_toggle_sync1_q <= consumed_toggle_pix_q;
            consumed_toggle_sync2_q <= consumed_toggle_sync1_q;
        end
    end

    always_ff @(posedge ui_clk) begin
        if (ui_reset) begin
            ui_state_q <= UI_IDLE;
            current_addr_q <= {29{1'b0}};
            remaining_beats_q <= 32'd0;
            burst_target_beats_q <= 9'd0;
            read_beat_q <= 8'd0;
            fetched_beats_q <= 32'd0;
            frame_error_q <= 1'b0;
            start_toggle_ui_q <= 1'b0;
            start_sent_q <= 1'b0;
            consumed_toggle_seen_q <= 1'b0;
            status_busy <= 1'b0;
            status_fetch_done <= 1'b0;
            status_fetch_success <= 1'b0;
            status_frame_done <= 1'b0;
            status_frame_success <= 1'b0;
            status_axi_error <= 1'b0;
            status_protocol_error <= 1'b0;
            first_error_kind <= ERROR_NONE;
            first_error_addr <= {29{1'b0}};
            first_error_resp <= 2'b00;
        end else begin
            status_fetch_done <= 1'b0;
            status_fetch_success <= 1'b0;
            status_frame_done <= 1'b0;
            status_frame_success <= 1'b0;

            unique case (ui_state_q)
                UI_IDLE: begin
                    if (command_accept) begin
                        current_addr_q <= command_base_addr;
                        remaining_beats_q <= FRAME_BEATS_VALUE;
                        burst_target_beats_q <= burst_beats_at(
                            command_base_addr[11:4],
                            FRAME_BEATS_VALUE
                        );
                        read_beat_q <= 8'd0;
                        fetched_beats_q <= 32'd0;
                        frame_error_q <= 1'b0;
                        start_sent_q <= 1'b0;
                        status_busy <= 1'b1;
                        ui_state_q <= UI_ISSUE_ADDRESS;
                    end
                end

                UI_ISSUE_ADDRESS: begin
                    if (ar_transfer) begin
                        read_beat_q <= 8'd0;
                        ui_state_q <= UI_RECEIVE_DATA;
                    end
                end

                UI_RECEIVE_DATA: begin
                    if (read_transfer) begin
                        fetched_beats_q <= fetched_beats_q + 32'd1;

                        if (!start_sent_q && start_threshold_reached) begin
                            start_toggle_ui_q <= ~start_toggle_ui_q;
                            start_sent_q <= 1'b1;
                        end

                        if (response_error_event) begin
                            frame_error_q <= 1'b1;
                            if (rresp_error || rid_error) begin
                                status_axi_error <= 1'b1;
                            end
                            if (rlast_error) begin
                                status_protocol_error <= 1'b1;
                            end

                            if (first_error_kind == ERROR_NONE) begin
                                first_error_kind <= rresp_error
                                    ? ERROR_RRESP
                                    : (rid_error ? ERROR_RID : ERROR_RLAST);
                                first_error_addr <= response_addr;
                                first_error_resp <= m_axi_rresp;
                            end
                        end

                        if (expected_burst_last_transfer) begin
                            if (expected_frame_last_transfer) begin
                                status_fetch_done <= 1'b1;
                                status_fetch_success <=
                                    !(frame_error_q || response_error_event);
                                ui_state_q <= UI_WAIT_CONSUME;
                            end else begin
                                current_addr_q <= next_addr;
                                remaining_beats_q <=
                                    remaining_beats_after_burst;
                                burst_target_beats_q <=
                                    next_burst_target_beats;
                                read_beat_q <= 8'd0;
                                ui_state_q <= UI_ISSUE_ADDRESS;
                            end
                        end else begin
                            read_beat_q <= read_beat_q + 1'b1;
                        end
                    end
                end

                default: begin
                    if (consumed_toggle_sync2_q
                        != consumed_toggle_seen_q) begin
                        consumed_toggle_seen_q <= consumed_toggle_sync2_q;
                        status_busy <= 1'b0;
                        status_frame_done <= 1'b1;
                        status_frame_success <= !frame_error_q;
                        ui_state_q <= UI_IDLE;
                    end
                end
            endcase
        end
    end

    // Synchronize the prefetch-complete start epoch into the pixel domain.
    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            start_toggle_sync1_q <= 1'b0;
            start_toggle_sync2_q <= 1'b0;
        end else begin
            start_toggle_sync1_q <= start_toggle_ui_q;
            start_toggle_sync2_q <= start_toggle_sync1_q;
        end
    end

    always_comb begin
        unique case (pixel_lane_q)
            2'd0: selected_rgb = fifo_m_data[23:0];
            2'd1: selected_rgb = fifo_m_data[55:32];
            2'd2: selected_rgb = fifo_m_data[87:64];
            default: selected_rgb = fifo_m_data[119:96];
        endcase
    end

    assign m_axis_tdata = selected_rgb;
    assign m_axis_tvalid = !pix_reset
        && (pixel_state_q == PIX_STREAM_FRAME)
        && fifo_m_valid;
    assign m_axis_tuser = (pixel_x_q == {X_COUNT_WIDTH{1'b0}})
        && (pixel_y_q == {Y_COUNT_WIDTH{1'b0}});
    assign m_axis_tlast = pixel_x_q == LAST_X;
    assign pixel_transfer = m_axis_tvalid && m_axis_tready;
    assign fifo_m_ready = pixel_transfer && (pixel_lane_q == 2'd3);
    assign frame_last_pixel = pixel_transfer
        && (pixel_x_q == LAST_X)
        && (pixel_y_q == LAST_Y);

    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            pixel_state_q <= PIX_WAIT_START;
            start_toggle_seen_q <= 1'b0;
            consumed_toggle_pix_q <= 1'b0;
            pixel_lane_q <= 2'd0;
            pixel_x_q <= {X_COUNT_WIDTH{1'b0}};
            pixel_y_q <= {Y_COUNT_WIDTH{1'b0}};
        end else begin
            unique case (pixel_state_q)
                PIX_WAIT_START: begin
                    if (start_toggle_sync2_q != start_toggle_seen_q) begin
                        start_toggle_seen_q <= start_toggle_sync2_q;
                        pixel_lane_q <= 2'd0;
                        pixel_x_q <= {X_COUNT_WIDTH{1'b0}};
                        pixel_y_q <= {Y_COUNT_WIDTH{1'b0}};
                        pixel_state_q <= PIX_STREAM_FRAME;
                    end
                end

                default: begin
                    if (pixel_transfer) begin
                        if (frame_last_pixel) begin
                            consumed_toggle_pix_q <= ~consumed_toggle_pix_q;
                            pixel_lane_q <= 2'd0;
                            pixel_x_q <= {X_COUNT_WIDTH{1'b0}};
                            pixel_y_q <= {Y_COUNT_WIDTH{1'b0}};
                            pixel_state_q <= PIX_WAIT_START;
                        end else begin
                            pixel_lane_q <= pixel_lane_q + 1'b1;

                            if (pixel_x_q == LAST_X) begin
                                pixel_x_q <= {X_COUNT_WIDTH{1'b0}};
                                pixel_y_q <= pixel_y_q + 1'b1;
                            end else begin
                                pixel_x_q <= pixel_x_q + 1'b1;
                            end
                        end
                    end
                end
            endcase
        end
    end

endmodule
