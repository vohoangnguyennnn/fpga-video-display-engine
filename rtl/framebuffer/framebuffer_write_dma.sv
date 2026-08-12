// Fixed-geometry AXI4-Stream to AXI4 framebuffer writer.
//
// One controller command owns one complete frame. RGB888 pixels enter in the
// pixel clock domain, cross through axis_async_fifo with SOF/EOL metadata, and
// are packed four-at-a-time into 128-bit XRGB8888 AXI beats. The UI-domain
// engine stages one burst, issues at most one outstanding write burst, and
// reports success only after the final BRESP is accepted.

module framebuffer_write_dma #(
    parameter integer FRAME_WIDTH = framebuffer_pkg::FRAME_WIDTH,
    parameter integer FRAME_HEIGHT = framebuffer_pkg::FRAME_HEIGHT,
    parameter integer STRIDE_BYTES = framebuffer_pkg::STRIDE_BYTES,
    parameter logic [28:0] FB0_BASE_ADDR = 29'(framebuffer_pkg::FB0_BASE_ADDR),
    parameter logic [28:0] FB1_BASE_ADDR = 29'(framebuffer_pkg::FB1_BASE_ADDR),
    parameter integer FB_SLOT_BYTES = framebuffer_pkg::FB_SLOT_BYTES,
    parameter integer BURST_BEATS = framebuffer_pkg::DMA_BURST_BEATS,
    parameter integer FIFO_DEPTH = 512,
    parameter logic [3:0] AXI_ID = 4'h1
) (
    // Pixel-domain AXI4-Stream Video input.
    input logic pix_clk,
    input logic pix_reset,
    input logic [23:0] s_axis_tdata,
    input logic s_axis_tvalid,
    output logic s_axis_tready,
    input logic s_axis_tuser,
    input logic s_axis_tlast,

    // UI-domain command from framebuffer_control. A command is accepted only
    // on cmd_valid && cmd_ready; cmd_buffer_index is then retained internally
    // through the final response.
    input logic ui_clk,
    input logic ui_reset,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic cmd_buffer_index,

    output logic status_busy,
    output logic status_frame_done,
    output logic status_frame_success,
    output logic status_axi_error,
    output logic status_protocol_error,

    // Sticky first-error telemetry. Kind: 0 none, 1 BRESP, 2 BID,
    // 3 AXI4-Stream framing.
    output logic [1:0] first_error_kind,
    output logic [28:0] first_error_addr,
    output logic [1:0] first_error_resp,

    // AXI4 write master. The MIG/interconnect contract is fixed at
    // 29-bit byte addresses, 128-bit data, and 4-bit IDs.
    output logic [3:0] m_axi_awid,
    output logic [28:0] m_axi_awaddr,
    output logic [7:0] m_axi_awlen,
    output logic [2:0] m_axi_awsize,
    output logic [1:0] m_axi_awburst,
    output logic [0:0] m_axi_awlock,
    output logic [3:0] m_axi_awcache,
    output logic [2:0] m_axi_awprot,
    output logic [3:0] m_axi_awqos,
    output logic m_axi_awvalid,
    input logic m_axi_awready,

    output logic [127:0] m_axi_wdata,
    output logic [15:0] m_axi_wstrb,
    output logic m_axi_wlast,
    output logic m_axi_wvalid,
    input logic m_axi_wready,

    input logic [3:0] m_axi_bid,
    input logic [1:0] m_axi_bresp,
    input logic m_axi_bvalid,
    output logic m_axi_bready
);

    localparam integer FIFO_PAYLOAD_WIDTH = 26;
    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam integer FRAME_BEATS =
        FRAME_PIXELS / framebuffer_pkg::PIXELS_PER_AXI_BEAT;
    localparam integer X_COUNT_WIDTH =
        (FRAME_WIDTH <= 1) ? 1 : $clog2(FRAME_WIDTH);
    localparam integer Y_COUNT_WIDTH =
        (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT);
    localparam integer PIXEL_COUNT_WIDTH =
        (FRAME_PIXELS <= 1) ? 1 : $clog2(FRAME_PIXELS);
    localparam integer BURST_INDEX_WIDTH =
        (BURST_BEATS <= 1) ? 1 : $clog2(BURST_BEATS);

    localparam logic [X_COUNT_WIDTH-1:0] LAST_X =
        X_COUNT_WIDTH'(FRAME_WIDTH - 1);
    localparam logic [Y_COUNT_WIDTH-1:0] LAST_Y =
        Y_COUNT_WIDTH'(FRAME_HEIGHT - 1);
    localparam logic [PIXEL_COUNT_WIDTH-1:0] LAST_PIXEL_COUNT =
        PIXEL_COUNT_WIDTH'(FRAME_PIXELS - 1);
    localparam logic [31:0] FRAME_BEATS_VALUE = 32'(FRAME_BEATS);
    localparam logic [29:0] FRAME_BYTES_VALUE = 30'(FRAME_HEIGHT * STRIDE_BYTES);
    localparam logic [29:0] FB0_END_ADDR = {1'b0, FB0_BASE_ADDR} + 30'(FB_SLOT_BYTES);
    localparam logic [29:0] FB1_END_ADDR = {1'b0, FB1_BASE_ADDR} + 30'(FB_SLOT_BYTES);
    localparam logic [29:0] MIG_END_ADDR = 30'h2000_0000;

    localparam logic [1:0] ERROR_NONE = 2'd0;
    localparam logic [1:0] ERROR_BRESP = 2'd1;
    localparam logic [1:0] ERROR_BID = 2'd2;
    localparam logic [1:0] ERROR_PROTOCOL = 2'd3;

    typedef enum logic [1:0] {
        PIX_WAIT_COMMAND,
        PIX_WAIT_SOF,
        PIX_CAPTURE_FRAME
    } pixel_state_t;

    typedef enum logic [2:0] {
        UI_IDLE,
        UI_WAIT_SOF,
        UI_FILL_BURST,
        UI_SEND_BURST,
        UI_WAIT_RESPONSE
    } ui_state_t;

    pixel_state_t pixel_state_q;
    ui_state_t ui_state_q;

    logic capture_toggle_ui_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic capture_toggle_sync1_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic capture_toggle_sync2_q;
    logic capture_toggle_seen_q;
    logic [PIXEL_COUNT_WIDTH-1:0] pixel_capture_count_q;

    logic [FIFO_PAYLOAD_WIDTH-1:0] fifo_s_payload;
    logic fifo_s_valid;
    logic fifo_s_ready;
    logic [FIFO_PAYLOAD_WIDTH-1:0] fifo_m_payload;
    logic fifo_m_valid;
    logic fifo_m_ready;
    logic fifo_pop;
    logic [23:0] fifo_rgb;
    logic fifo_sof;
    logic fifo_eol;

    logic [127:0] burst_memory [0:BURST_BEATS-1];
    logic [127:0] pack_data_q;
    logic [127:0] pack_data_with_pixel;
    logic [1:0] pack_pixel_count_q;
    logic [8:0] staged_beats_q;
    logic [8:0] burst_target_beats_q;
    logic [7:0] write_beat_q;

    logic [28:0] frame_base_addr_q;
    logic [28:0] current_addr_q;
    logic [28:0] pixel_addr_q;
    logic [31:0] remaining_beats_q;
    logic [28:0] next_addr;
    logic [31:0] remaining_beats_after_burst;
    logic [12:0] active_burst_bytes;
    logic [8:0] next_burst_target_beats;

    logic [X_COUNT_WIDTH-1:0] pixel_x_q;
    logic [Y_COUNT_WIDTH-1:0] pixel_y_q;
    logic frame_error_q;

    logic awvalid_q;
    logic wvalid_q;

    logic frame_pixel_accept;
    logic discarded_before_sof;
    logic expected_sof;
    logic expected_eol;
    logic protocol_error_event;
    logic [28:0] protocol_error_addr;
    logic beat_completed;
    logic burst_completed;
    logic frame_last_pixel;
    logic response_error;
    logic command_accept;
    logic [28:0] command_base_addr;

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
            else $fatal(1, "framebuffer_write_dma FRAME_WIDTH is too small");
        assert (FRAME_HEIGHT >= 1)
            else $fatal(1, "framebuffer_write_dma FRAME_HEIGHT must be positive");
        assert ((FRAME_WIDTH % framebuffer_pkg::PIXELS_PER_AXI_BEAT) == 0)
            else $fatal(1, "framebuffer_write_dma lines must contain whole AXI beats");
        assert (STRIDE_BYTES == (FRAME_WIDTH * framebuffer_pkg::BYTES_PER_PIXEL))
            else $fatal(1, "framebuffer_write_dma baseline does not permit line padding");
        assert (FRAME_BYTES_VALUE <= 30'(FB_SLOT_BYTES))
            else $fatal(1, "framebuffer_write_dma frame exceeds one slot");
        assert ((FB0_BASE_ADDR[11:0] == 12'b0)
            && (FB1_BASE_ADDR[11:0] == 12'b0))
            else $fatal(1, "framebuffer_write_dma slot bases must be 4-KiB aligned");
        assert ((FB0_END_ADDR <= {1'b0, FB1_BASE_ADDR})
            && (FB1_END_ADDR <= MIG_END_ADDR))
            else $fatal(1, "framebuffer_write_dma slots overlap or exceed MIG memory");
        assert ((BURST_BEATS >= 1) && (BURST_BEATS <= 256))
            else $fatal(1, "framebuffer_write_dma BURST_BEATS must be in 1..256");
        assert ((FIFO_DEPTH >= 4) && ((FIFO_DEPTH & (FIFO_DEPTH - 1)) == 0))
            else $fatal(1, "framebuffer_write_dma FIFO_DEPTH must be a power of two >= 4");
    end

    assign command_base_addr = cmd_buffer_index
        ? FB1_BASE_ADDR : FB0_BASE_ADDR;
    assign cmd_ready = !ui_reset && (ui_state_q == UI_IDLE);
    assign command_accept = cmd_valid && cmd_ready;

    assign fifo_s_payload = {s_axis_tlast, s_axis_tuser, s_axis_tdata};
    assign fifo_s_valid = s_axis_tvalid
        && !pix_reset
        && ((pixel_state_q == PIX_WAIT_SOF)
            || (pixel_state_q == PIX_CAPTURE_FRAME));
    assign s_axis_tready = fifo_s_ready
        && !pix_reset
        && ((pixel_state_q == PIX_WAIT_SOF)
            || (pixel_state_q == PIX_CAPTURE_FRAME));

    axis_async_fifo #(
        .DATA_WIDTH(FIFO_PAYLOAD_WIDTH),
        .DEPTH(FIFO_DEPTH)
    ) u_pixel_to_ui_fifo (
        .s_axis_aclk(pix_clk),
        .s_axis_aresetn(!pix_reset),
        .s_axis_tdata(fifo_s_payload),
        .s_axis_tvalid(fifo_s_valid),
        .s_axis_tready(fifo_s_ready),
        .m_axis_aclk(ui_clk),
        .m_axis_aresetn(!ui_reset),
        .m_axis_tdata(fifo_m_payload),
        .m_axis_tvalid(fifo_m_valid),
        .m_axis_tready(fifo_m_ready)
    );

    assign fifo_rgb = fifo_m_payload[23:0];
    assign fifo_sof = fifo_m_payload[24];
    assign fifo_eol = fifo_m_payload[25];
    assign fifo_m_ready = !ui_reset
        && ((ui_state_q == UI_WAIT_SOF)
            || (ui_state_q == UI_FILL_BURST));
    assign fifo_pop = fifo_m_valid && fifo_m_ready;

    assign frame_pixel_accept = fifo_pop
        && ((ui_state_q == UI_FILL_BURST)
            || ((ui_state_q == UI_WAIT_SOF) && fifo_sof));
    assign discarded_before_sof = fifo_pop
        && (ui_state_q == UI_WAIT_SOF)
        && !fifo_sof;
    assign expected_sof = (pixel_x_q == {X_COUNT_WIDTH{1'b0}})
        && (pixel_y_q == {Y_COUNT_WIDTH{1'b0}});
    assign expected_eol = pixel_x_q == LAST_X;
    assign protocol_error_event = discarded_before_sof
        || (frame_pixel_accept
            && ((fifo_sof != expected_sof) || (fifo_eol != expected_eol)));
    assign protocol_error_addr = discarded_before_sof
        ? frame_base_addr_q : pixel_addr_q;

    always_comb begin
        pack_data_with_pixel = pack_data_q;
        unique case (pack_pixel_count_q)
            2'd0: pack_data_with_pixel[31:0] =
                framebuffer_pkg::pack_xrgb8888(fifo_rgb);
            2'd1: pack_data_with_pixel[63:32] =
                framebuffer_pkg::pack_xrgb8888(fifo_rgb);
            2'd2: pack_data_with_pixel[95:64] =
                framebuffer_pkg::pack_xrgb8888(fifo_rgb);
            default: pack_data_with_pixel[127:96] =
                framebuffer_pkg::pack_xrgb8888(fifo_rgb);
        endcase
    end

    assign beat_completed = frame_pixel_accept
        && (pack_pixel_count_q == 2'd3);
    assign burst_completed = beat_completed
        && ((staged_beats_q + 9'd1) == burst_target_beats_q);
    assign frame_last_pixel = frame_pixel_accept
        && (pixel_x_q == LAST_X)
        && (pixel_y_q == LAST_Y);

    assign active_burst_bytes = {burst_target_beats_q, 4'b0000};
    assign next_addr = current_addr_q
        + {{16{1'b0}}, active_burst_bytes};
    assign remaining_beats_after_burst = remaining_beats_q
        - {23'd0, burst_target_beats_q};
    assign next_burst_target_beats = burst_beats_at(
        next_addr[11:4],
        remaining_beats_after_burst
    );
    assign response_error = (m_axi_bresp != 2'b00) || (m_axi_bid != AXI_ID);

    assign m_axi_awid = AXI_ID;
    assign m_axi_awaddr = current_addr_q;
    assign m_axi_awlen = burst_target_beats_q[7:0] - 8'd1;
    assign m_axi_awsize = framebuffer_pkg::AXI_BEAT_SIZE;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awlock = 1'b0;
    assign m_axi_awcache = 4'b0011;
    assign m_axi_awprot = 3'b000;
    assign m_axi_awqos = 4'b0000;
    assign m_axi_awvalid = awvalid_q;

    assign m_axi_wdata = burst_memory[
        write_beat_q[BURST_INDEX_WIDTH-1:0]
    ];
    assign m_axi_wstrb = 16'hffff;
    assign m_axi_wlast = ({1'b0, write_beat_q} + 9'd1)
        == burst_target_beats_q;
    assign m_axi_wvalid = wvalid_q;
    assign m_axi_bready = ui_state_q == UI_WAIT_RESPONSE;

    // Synchronize the one-bit command epoch into the pixel domain. A second
    // command cannot be issued until the first frame reaches a terminal BRESP,
    // so the toggle cannot wrap before the pixel side observes it.
    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            capture_toggle_sync1_q <= 1'b0;
            capture_toggle_sync2_q <= 1'b0;
        end else begin
            capture_toggle_sync1_q <= capture_toggle_ui_q;
            capture_toggle_sync2_q <= capture_toggle_sync1_q;
        end
    end

    // Pixel-domain frame admission. Non-SOF tokens are accepted and forwarded
    // after a command so malformed sources cannot deadlock while presenting a
    // held transfer; the UI side marks the command failed and searches for SOF.
    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            pixel_state_q <= PIX_WAIT_COMMAND;
            capture_toggle_seen_q <= 1'b0;
            pixel_capture_count_q <= {PIXEL_COUNT_WIDTH{1'b0}};
        end else begin
            unique case (pixel_state_q)
                PIX_WAIT_COMMAND: begin
                    if (capture_toggle_sync2_q != capture_toggle_seen_q) begin
                        capture_toggle_seen_q <= capture_toggle_sync2_q;
                        pixel_capture_count_q <= {PIXEL_COUNT_WIDTH{1'b0}};
                        pixel_state_q <= PIX_WAIT_SOF;
                    end
                end

                PIX_WAIT_SOF: begin
                    if (s_axis_tvalid && s_axis_tready && s_axis_tuser) begin
                        pixel_capture_count_q <= PIXEL_COUNT_WIDTH'(1);
                        pixel_state_q <= PIX_CAPTURE_FRAME;
                    end
                end

                default: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        if (pixel_capture_count_q == LAST_PIXEL_COUNT) begin
                            pixel_capture_count_q <= {PIXEL_COUNT_WIDTH{1'b0}};
                            pixel_state_q <= PIX_WAIT_COMMAND;
                        end else begin
                            pixel_capture_count_q <= pixel_capture_count_q + 1'b1;
                        end
                    end
                end
            endcase
        end
    end

    always_ff @(posedge ui_clk) begin
        if (ui_reset) begin
            ui_state_q <= UI_IDLE;
            capture_toggle_ui_q <= 1'b0;
            status_busy <= 1'b0;
            status_frame_done <= 1'b0;
            status_frame_success <= 1'b0;
            status_axi_error <= 1'b0;
            status_protocol_error <= 1'b0;
            first_error_kind <= ERROR_NONE;
            first_error_addr <= {29{1'b0}};
            first_error_resp <= 2'b00;
            frame_error_q <= 1'b0;
            frame_base_addr_q <= {29{1'b0}};
            current_addr_q <= {29{1'b0}};
            pixel_addr_q <= {29{1'b0}};
            remaining_beats_q <= 32'd0;
            burst_target_beats_q <= 9'd0;
            staged_beats_q <= 9'd0;
            pack_pixel_count_q <= 2'd0;
            pack_data_q <= {128{1'b0}};
            pixel_x_q <= {X_COUNT_WIDTH{1'b0}};
            pixel_y_q <= {Y_COUNT_WIDTH{1'b0}};
            write_beat_q <= 8'd0;
            awvalid_q <= 1'b0;
            wvalid_q <= 1'b0;
        end else begin
            status_frame_done <= 1'b0;
            status_frame_success <= 1'b0;

            unique case (ui_state_q)
                UI_IDLE: begin
                    awvalid_q <= 1'b0;
                    wvalid_q <= 1'b0;

                    if (command_accept) begin
                        capture_toggle_ui_q <= ~capture_toggle_ui_q;
                        status_busy <= 1'b1;
                        frame_error_q <= 1'b0;
                        frame_base_addr_q <= command_base_addr;
                        current_addr_q <= command_base_addr;
                        pixel_addr_q <= command_base_addr;
                        remaining_beats_q <= FRAME_BEATS_VALUE;
                        burst_target_beats_q <= burst_beats_at(
                            command_base_addr[11:4],
                            FRAME_BEATS_VALUE
                        );
                        staged_beats_q <= 9'd0;
                        pack_pixel_count_q <= 2'd0;
                        pixel_x_q <= {X_COUNT_WIDTH{1'b0}};
                        pixel_y_q <= {Y_COUNT_WIDTH{1'b0}};
                        ui_state_q <= UI_WAIT_SOF;
                    end
                end

                UI_WAIT_SOF: begin
                    if (fifo_pop && fifo_sof) begin
                        ui_state_q <= UI_FILL_BURST;
                    end
                end

                UI_FILL_BURST: begin
                    // Pixel packing below owns the transition to SEND_BURST.
                end

                UI_SEND_BURST: begin
                    if (awvalid_q && m_axi_awready) begin
                        awvalid_q <= 1'b0;
                    end

                    if (wvalid_q && m_axi_wready) begin
                        if (m_axi_wlast) begin
                            wvalid_q <= 1'b0;
                        end else begin
                            write_beat_q <= write_beat_q + 1'b1;
                        end
                    end

                    if ((!awvalid_q || m_axi_awready)
                        && (!wvalid_q || (m_axi_wready && m_axi_wlast))) begin
                        ui_state_q <= UI_WAIT_RESPONSE;
                    end
                end

                default: begin
                    if (m_axi_bvalid) begin
                        if (response_error) begin
                            frame_error_q <= 1'b1;
                            status_axi_error <= 1'b1;

                            if (first_error_kind == ERROR_NONE) begin
                                first_error_kind <= (m_axi_bresp != 2'b00)
                                    ? ERROR_BRESP : ERROR_BID;
                                first_error_addr <= current_addr_q;
                                first_error_resp <= m_axi_bresp;
                            end
                        end

                        if (remaining_beats_q
                            == {23'd0, burst_target_beats_q}) begin
                            status_busy <= 1'b0;
                            status_frame_done <= 1'b1;
                            status_frame_success <=
                                !(frame_error_q || response_error);
                            ui_state_q <= UI_IDLE;
                        end else begin
                            current_addr_q <= next_addr;
                            remaining_beats_q <= remaining_beats_after_burst;
                            burst_target_beats_q <= next_burst_target_beats;
                            staged_beats_q <= 9'd0;
                            pack_pixel_count_q <= 2'd0;
                            ui_state_q <= UI_FILL_BURST;
                        end
                    end
                end
            endcase

            if (protocol_error_event) begin
                frame_error_q <= 1'b1;
                status_protocol_error <= 1'b1;

                if (first_error_kind == ERROR_NONE) begin
                    first_error_kind <= ERROR_PROTOCOL;
                    first_error_addr <= protocol_error_addr;
                    first_error_resp <= 2'b00;
                end
            end

            if (frame_pixel_accept) begin
                pack_data_q <= pack_data_with_pixel;

                if (pack_pixel_count_q == 2'd3) begin
                    burst_memory[staged_beats_q[BURST_INDEX_WIDTH-1:0]] <=
                        pack_data_with_pixel;
                    pack_pixel_count_q <= 2'd0;

                    if (burst_completed) begin
                        write_beat_q <= 8'd0;
                        awvalid_q <= 1'b1;
                        wvalid_q <= 1'b1;
                        ui_state_q <= UI_SEND_BURST;
                    end else begin
                        staged_beats_q <= staged_beats_q + 1'b1;
                    end
                end else begin
                    pack_pixel_count_q <= pack_pixel_count_q + 1'b1;
                end

                pixel_addr_q <= pixel_addr_q
                    + 29'(framebuffer_pkg::BYTES_PER_PIXEL);

                if (frame_last_pixel) begin
                    pixel_x_q <= {X_COUNT_WIDTH{1'b0}};
                    pixel_y_q <= {Y_COUNT_WIDTH{1'b0}};
                end else if (pixel_x_q == LAST_X) begin
                    pixel_x_q <= {X_COUNT_WIDTH{1'b0}};
                    pixel_y_q <= pixel_y_q + 1'b1;
                end else begin
                    pixel_x_q <= pixel_x_q + 1'b1;
                end
            end
        end
    end

endmodule
