// Fixed-policy two-slot framebuffer ownership controller.
//
// The controller lives primarily in the MIG UI clock domain. A vertical-blank
// event crosses from the pixel domain through a toggle/acknowledge handshake;
// DMA commands and completion status are already synchronous to ui_clk. Only
// complete successful writes may move FREE -> WRITING -> READY -> READING.

module framebuffer_control (
    // Pixel-domain vertical-blank request. vblank_start is one pix_clk pulse
    // at raster coordinate (0, FRAME_HEIGHT).
    input logic pix_clk,
    input logic pix_reset,
    input logic vblank_start,
    output logic display_valid_pix,

    // MIG UI/control domain. ui_reset aborts all ownership and returns both
    // framebuffer slots to FREE; top-level holds it active until DDR/BIST is
    // ready for video use.
    input logic ui_clk,
    input logic ui_reset,

    // Write-DMA command and terminal response.
    output logic wdma_cmd_valid,
    input logic wdma_cmd_ready,
    output logic wdma_cmd_buffer_index,
    input logic wdma_status_frame_done,
    input logic wdma_status_frame_success,

    // Read-DMA command and terminal stream response.
    output logic rdma_cmd_valid,
    input logic rdma_cmd_ready,
    output logic rdma_cmd_buffer_index,
    input logic rdma_status_frame_done,
    input logic rdma_status_frame_success,

    // UI-domain ownership/debug status. Slot encoding:
    // 0 FREE, 1 WRITING, 2 READY, 3 READING.
    output logic front_buffer_index,
    output logic back_buffer_index,
    output logic [1:0] slot0_state,
    output logic [1:0] slot1_state,
    output logic status_display_valid,
    output logic status_swap,
    output logic status_repeat_frame,
    output logic status_write_error,
    output logic status_read_error,
    output logic status_read_deadline_miss,
    output logic status_ownership_error
);

    localparam logic [1:0] SLOT_FREE = 2'd0;
    localparam logic [1:0] SLOT_WRITING = 2'd1;
    localparam logic [1:0] SLOT_READY = 2'd2;
    localparam logic [1:0] SLOT_READING = 2'd3;

    logic [1:0] slot0_state_q;
    logic [1:0] slot1_state_q;
    logic front_buffer_index_q;
    logic back_buffer_index_q;
    logic display_valid_ui_q;

    logic wdma_cmd_valid_q;
    logic wdma_cmd_buffer_index_q;
    logic write_inflight_q;
    logic write_active_index_q;

    logic rdma_cmd_valid_q;
    logic rdma_cmd_buffer_index_q;
    logic read_inflight_q;
    logic read_active_index_q;
    logic read_released_q;

    // Pixel-to-UI vertical-blank request and UI-to-pixel acknowledge.
    logic vblank_request_pix_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic vblank_ack_sync1_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic vblank_ack_sync2_q;

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic vblank_request_sync1_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic vblank_request_sync2_q;
    logic vblank_request_seen_q;
    logic vblank_ack_ui_q;
    logic [1:0] vblank_sync_arm_q;
    logic vblank_sync_armed_q;
    logic vblank_pending_q;

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic display_valid_sync1_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic display_valid_sync2_q;

    logic [1:0] front_slot_state;
    logic [1:0] back_slot_state;
    logic successful_write_now;
    logic read_completion_now;
    logic back_ready_now;
    logic ownership_violation;
    logic wdma_command_accept;
    logic rdma_command_accept;

    assign wdma_cmd_valid = wdma_cmd_valid_q;
    assign wdma_cmd_buffer_index = wdma_cmd_buffer_index_q;
    assign rdma_cmd_valid = rdma_cmd_valid_q;
    assign rdma_cmd_buffer_index = rdma_cmd_buffer_index_q;
    assign wdma_command_accept = wdma_cmd_valid && wdma_cmd_ready;
    assign rdma_command_accept = rdma_cmd_valid && rdma_cmd_ready;

    assign front_buffer_index = front_buffer_index_q;
    assign back_buffer_index = back_buffer_index_q;
    assign slot0_state = slot0_state_q;
    assign slot1_state = slot1_state_q;
    assign status_display_valid = display_valid_ui_q;

    assign front_slot_state = front_buffer_index_q ? slot1_state_q : slot0_state_q;
    assign back_slot_state = back_buffer_index_q ? slot1_state_q : slot0_state_q;

    // Terminal responses coincident with a pending vblank defer resolution by
    // one UI cycle. This lets the slot visibly enter READY/FREE before the
    // next legal ownership transition while remaining deep inside blanking.
    assign successful_write_now = wdma_status_frame_done
        && wdma_status_frame_success
        && write_inflight_q
        && (write_active_index_q == back_buffer_index_q);
    assign read_completion_now = rdma_status_frame_done
        && read_inflight_q;
    assign back_ready_now = back_slot_state == SLOT_READY;

    assign ownership_violation =
        (front_buffer_index_q == back_buffer_index_q)
        || (display_valid_ui_q && (front_slot_state != SLOT_READING))
        || (back_slot_state == SLOT_READING)
        || (wdma_cmd_valid_q && display_valid_ui_q
            && (wdma_cmd_buffer_index_q == front_buffer_index_q))
        || (rdma_cmd_valid_q
            && (!display_valid_ui_q
                || (rdma_cmd_buffer_index_q != front_buffer_index_q)))
        || (write_inflight_q && display_valid_ui_q
            && (write_active_index_q == front_buffer_index_q))
        || (read_inflight_q
            && (read_active_index_q != front_buffer_index_q))
        || (write_inflight_q && read_inflight_q
            && (write_active_index_q == read_active_index_q));

    // Source half of the vertical-blank event handshake. A request remains
    // encoded in the toggle until the UI domain returns the same epoch.
    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            vblank_request_pix_q <= 1'b0;
            vblank_ack_sync1_q <= 1'b0;
            vblank_ack_sync2_q <= 1'b0;
        end else begin
            vblank_ack_sync1_q <= vblank_ack_ui_q;
            vblank_ack_sync2_q <= vblank_ack_sync1_q;

            if (vblank_start
                && (vblank_ack_sync2_q == vblank_request_pix_q)) begin
                vblank_request_pix_q <= ~vblank_request_pix_q;
            end
        end
    end

    // display_valid is a level, not a pulse. It becomes high only after the
    // first READY slot is promoted and remains high until reset.
    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            display_valid_sync1_q <= 1'b0;
            display_valid_sync2_q <= 1'b0;
        end else begin
            display_valid_sync1_q <= display_valid_ui_q;
            display_valid_sync2_q <= display_valid_sync1_q;
        end
    end

    assign display_valid_pix = display_valid_sync2_q;

    // Destination half of the vertical-blank handshake. Arming establishes a
    // reset baseline instead of interpreting a stale reset-domain mismatch as
    // a real event.
    always_ff @(posedge ui_clk) begin
        if (ui_reset) begin
            vblank_request_sync1_q <= 1'b0;
            vblank_request_sync2_q <= 1'b0;
        end else begin
            vblank_request_sync1_q <= vblank_request_pix_q;
            vblank_request_sync2_q <= vblank_request_sync1_q;
        end
    end

    always_ff @(posedge ui_clk) begin
        if (ui_reset) begin
            slot0_state_q <= SLOT_FREE;
            slot1_state_q <= SLOT_FREE;
            // Before first promotion these indices identify the chosen first
            // back slot and the other invalid slot; they are still distinct.
            front_buffer_index_q <= 1'b1;
            back_buffer_index_q <= 1'b0;
            display_valid_ui_q <= 1'b0;

            wdma_cmd_valid_q <= 1'b0;
            wdma_cmd_buffer_index_q <= 1'b0;
            write_inflight_q <= 1'b0;
            write_active_index_q <= 1'b0;

            rdma_cmd_valid_q <= 1'b0;
            rdma_cmd_buffer_index_q <= 1'b0;
            read_inflight_q <= 1'b0;
            read_active_index_q <= 1'b0;
            read_released_q <= 1'b1;

            vblank_request_seen_q <= 1'b0;
            vblank_ack_ui_q <= 1'b0;
            vblank_sync_arm_q <= 2'b00;
            vblank_sync_armed_q <= 1'b0;
            vblank_pending_q <= 1'b0;

            status_swap <= 1'b0;
            status_repeat_frame <= 1'b0;
            status_write_error <= 1'b0;
            status_read_error <= 1'b0;
            status_read_deadline_miss <= 1'b0;
            status_ownership_error <= 1'b0;
        end else begin
            status_swap <= 1'b0;
            status_repeat_frame <= 1'b0;

            // Start the initial fill of FB0. No reader is enabled until this
            // write reaches READY and a later vertical blank promotes it.
            if (!display_valid_ui_q
                && (slot0_state_q == SLOT_FREE)
                && (slot1_state_q == SLOT_FREE)
                && !wdma_cmd_valid_q
                && !write_inflight_q) begin
                wdma_cmd_buffer_index_q <= back_buffer_index_q;
                wdma_cmd_valid_q <= 1'b1;
            end

            if (wdma_command_accept) begin
                wdma_cmd_valid_q <= 1'b0;
                write_inflight_q <= 1'b1;
                write_active_index_q <= wdma_cmd_buffer_index_q;

                if (wdma_cmd_buffer_index_q) begin
                    if (slot1_state_q != SLOT_FREE) begin
                        status_ownership_error <= 1'b1;
                    end
                    slot1_state_q <= SLOT_WRITING;
                end else begin
                    if (slot0_state_q != SLOT_FREE) begin
                        status_ownership_error <= 1'b1;
                    end
                    slot0_state_q <= SLOT_WRITING;
                end
            end

            if (rdma_command_accept) begin
                rdma_cmd_valid_q <= 1'b0;
                read_inflight_q <= 1'b1;
                read_active_index_q <= rdma_cmd_buffer_index_q;

                if (!display_valid_ui_q
                    || (rdma_cmd_buffer_index_q
                        != front_buffer_index_q)) begin
                    status_ownership_error <= 1'b1;
                end
            end

            if (wdma_status_frame_done) begin
                if (!write_inflight_q) begin
                    status_ownership_error <= 1'b1;
                end else begin
                    write_inflight_q <= 1'b0;

                    if (write_active_index_q) begin
                        if (slot1_state_q != SLOT_WRITING) begin
                            status_ownership_error <= 1'b1;
                        end
                        slot1_state_q <= wdma_status_frame_success
                            ? SLOT_READY : SLOT_FREE;
                    end else begin
                        if (slot0_state_q != SLOT_WRITING) begin
                            status_ownership_error <= 1'b1;
                        end
                        slot0_state_q <= wdma_status_frame_success
                            ? SLOT_READY : SLOT_FREE;
                    end

                    if (!wdma_status_frame_success) begin
                        status_write_error <= 1'b1;
                        // Lossless policy retries the same free back slot. The
                        // failed partial frame can never become READY.
                        wdma_cmd_buffer_index_q <= write_active_index_q;
                        wdma_cmd_valid_q <= 1'b1;
                    end
                end
            end

            if (rdma_status_frame_done) begin
                if (!read_inflight_q) begin
                    status_ownership_error <= 1'b1;
                end else begin
                    read_inflight_q <= 1'b0;
                    read_released_q <= 1'b1;
                    if (!rdma_status_frame_success) begin
                        status_read_error <= 1'b1;
                    end
                end
            end

            if (!vblank_sync_armed_q) begin
                vblank_sync_arm_q <= {
                    vblank_sync_arm_q[0], 1'b1
                };
                if (&vblank_sync_arm_q) begin
                    vblank_request_seen_q <=
                        vblank_request_sync2_q;
                    vblank_ack_ui_q <= vblank_request_sync2_q;
                    vblank_sync_armed_q <= 1'b1;
                end
            end else if (vblank_request_sync2_q
                != vblank_request_seen_q) begin
                vblank_request_seen_q <= vblank_request_sync2_q;
                vblank_ack_ui_q <= vblank_request_sync2_q;
                vblank_pending_q <= 1'b1;
            end

            // Resolve each vblank request exactly once. If a read missed the
            // deadline, no late mid-frame command is launched; recovery waits
            // for the next real vblank event.
            if (vblank_pending_q) begin
                if (successful_write_now || read_completion_now) begin
                    vblank_pending_q <= 1'b1;
                end else if (!display_valid_ui_q) begin
                    vblank_pending_q <= 1'b0;
                    if (back_ready_now) begin
                        front_buffer_index_q <= back_buffer_index_q;
                        back_buffer_index_q <= ~back_buffer_index_q;
                        display_valid_ui_q <= 1'b1;
                        read_released_q <= 1'b0;

                        rdma_cmd_buffer_index_q <=
                            back_buffer_index_q;
                        rdma_cmd_valid_q <= 1'b1;
                        wdma_cmd_buffer_index_q <=
                            ~back_buffer_index_q;
                        wdma_cmd_valid_q <= 1'b1;

                        if (back_buffer_index_q) begin
                            slot1_state_q <= SLOT_READING;
                            slot0_state_q <= SLOT_FREE;
                        end else begin
                            slot0_state_q <= SLOT_READING;
                            slot1_state_q <= SLOT_FREE;
                        end
                        status_swap <= 1'b1;
                    end
                end else if (!read_released_q) begin
                    vblank_pending_q <= 1'b0;
                    status_read_deadline_miss <= 1'b1;
                end else if (back_ready_now) begin
                    vblank_pending_q <= 1'b0;
                    // Atomic promotion: new front and back indices change on
                    // one UI edge; the old front becomes FREE before its next
                    // write command can be accepted.
                    front_buffer_index_q <= back_buffer_index_q;
                    back_buffer_index_q <= front_buffer_index_q;
                    read_released_q <= 1'b0;

                    rdma_cmd_buffer_index_q <=
                        back_buffer_index_q;
                    rdma_cmd_valid_q <= 1'b1;
                    wdma_cmd_buffer_index_q <=
                        front_buffer_index_q;
                    wdma_cmd_valid_q <= 1'b1;

                    if (back_buffer_index_q) begin
                        slot1_state_q <= SLOT_READING;
                        slot0_state_q <= SLOT_FREE;
                    end else begin
                        slot0_state_q <= SLOT_READING;
                        slot1_state_q <= SLOT_FREE;
                    end
                    status_swap <= 1'b1;
                end else begin
                    vblank_pending_q <= 1'b0;
                    // Back frame is incomplete or failed. Keep both indices
                    // unchanged and reread the complete old front frame.
                    read_released_q <= 1'b0;
                    rdma_cmd_buffer_index_q <=
                        front_buffer_index_q;
                    rdma_cmd_valid_q <= 1'b1;
                    status_repeat_frame <= 1'b1;
                end
            end

            if (ownership_violation) begin
                status_ownership_error <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    logic [1:0] previous_slot0_state_q;
    logic [1:0] previous_slot1_state_q;

    function automatic logic legal_slot_transition(
        input logic [1:0] previous_state,
        input logic [1:0] current_state
    );
        begin
            unique case (previous_state)
                SLOT_FREE: legal_slot_transition =
                    (current_state == SLOT_FREE)
                    || (current_state == SLOT_WRITING);
                SLOT_WRITING: legal_slot_transition =
                    (current_state == SLOT_WRITING)
                    || (current_state == SLOT_READY)
                    || (current_state == SLOT_FREE);
                SLOT_READY: legal_slot_transition =
                    (current_state == SLOT_READY)
                    || (current_state == SLOT_READING);
                default: legal_slot_transition =
                    (current_state == SLOT_READING)
                    || (current_state == SLOT_FREE);
            endcase
        end
    endfunction

    always_ff @(posedge ui_clk) begin
        if (ui_reset) begin
            previous_slot0_state_q <= SLOT_FREE;
            previous_slot1_state_q <= SLOT_FREE;
        end else begin
            assert (legal_slot_transition(
                previous_slot0_state_q, slot0_state_q))
                else $error("illegal framebuffer slot0 state transition");
            assert (legal_slot_transition(
                previous_slot1_state_q, slot1_state_q))
                else $error("illegal framebuffer slot1 state transition");
            assert (!ownership_violation)
                else $error("framebuffer ownership invariant violated");

            previous_slot0_state_q <= slot0_state_q;
            previous_slot1_state_q <= slot1_state_q;
        end
    end
`endif

endmodule
