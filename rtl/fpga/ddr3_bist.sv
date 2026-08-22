// Destructive AXI4 DDR3 bring-up test for the reserved framebuffer aperture.
//
// The BIST runs in the MIG ui_clk domain after ddr3_mig_wrapper has released
// ui_reset. It uses one outstanding INCR burst and executes these full-aperture
// write/read/compare passes:
//   1. walking one for every bit of the 128-bit AXI beat;
//   2. walking zero for every bit of the 128-bit AXI beat;
//   3. byte-address pattern;
//   4. inverse byte-address pattern;
//   5. deterministic pseudorandom address hash.
//
// The default 8 MiB range covers the two 4 MiB framebuffer slots from the
// design specification. This module owns no video, DMA, or buffer policy.

module ddr3_bist #(
    parameter logic [28:0] BIST_BASE_ADDR = 29'h0000_0000,
    parameter logic [29:0] BIST_APERTURE_BYTES = 30'd8_388_608,
    parameter logic [8:0] BURST_BEATS = 9'd16,
    parameter logic [3:0] AXI_ID = 4'h0
) (
    input logic ui_clk,
    input logic ui_reset,
    input logic start,

    output logic status_busy,
    output logic status_done,
    output logic status_pass,
    output logic status_error,
    output logic [2:0] status_pattern,
    output logic [6:0] status_walk_bit,
    output logic [28:0] status_current_addr,

    // First-error telemetry remains valid until reset or the next accepted
    // start. Error kind: 0 none, 1 BRESP, 2 RRESP, 3 data, 4 BID, 5 RID,
    // 6 malformed RLAST.
    output logic [2:0] first_error_kind,
    output logic [28:0] first_error_addr,
    output logic [127:0] first_error_expected,
    output logic [127:0] first_error_actual,
    output logic [1:0] first_error_resp,

    // AXI4 master interface. The generated MIG contract is 29/128/4 bits.
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
    output logic m_axi_bready,

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

    localparam logic [29:0] MIG_CAPACITY_BYTES = 30'h2000_0000;
    localparam logic [29:0] BIST_END_ADDR =
        {1'b0, BIST_BASE_ADDR} + BIST_APERTURE_BYTES;

    localparam logic [2:0] PATTERN_WALKING_ONE = 3'd0;
    localparam logic [2:0] PATTERN_WALKING_ZERO = 3'd1;
    localparam logic [2:0] PATTERN_ADDRESS = 3'd2;
    localparam logic [2:0] PATTERN_INVERSE_ADDRESS = 3'd3;
    localparam logic [2:0] PATTERN_PSEUDORANDOM = 3'd4;

    localparam logic [2:0] ERROR_NONE = 3'd0;
    localparam logic [2:0] ERROR_BRESP = 3'd1;
    localparam logic [2:0] ERROR_RRESP = 3'd2;
    localparam logic [2:0] ERROR_DATA = 3'd3;
    localparam logic [2:0] ERROR_BID = 3'd4;
    localparam logic [2:0] ERROR_RID = 3'd5;
    localparam logic [2:0] ERROR_RLAST = 3'd6;

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_CALCULATE_WRITE,
        ST_PREPARE_WRITE,
        ST_WRITE_BURST,
        ST_WRITE_RESPONSE,
        ST_CALCULATE_READ,
        ST_PREPARE_READ,
        ST_READ_ADDRESS,
        ST_READ_DATA,
        ST_FINISH_READ_BURST,
        ST_DRAIN_READ
    } state_t;

    state_t state_q;
    logic start_q;
    logic [2:0] pattern_q;
    logic [6:0] walk_bit_q;
    logic [28:0] current_addr_q;
    logic [7:0] burst_len_q;
    logic [7:0] write_beat_q;
    logic [7:0] read_beat_q;
    logic [29:0] next_addr_q;
    logic awvalid_q;
    logic wvalid_q;
    logic arvalid_q;
    logic read_burst_error_q;
    logic [127:0] write_pattern_q;

    logic [8:0] active_burst_beats;
    logic [12:0] active_burst_bytes;
    logic [29:0] next_addr_ext;
    logic [28:0] write_beat_addr;
    logic [28:0] read_beat_addr;
    logic [28:0] pattern_beat_addr;
    logic [127:0] active_pattern_data;
    logic [127:0] read_expected_data;
    logic read_expected_last;
    logic [2:0] read_error_kind;
    logic read_beat_error;

    function automatic logic [31:0] hash32(input logic [31:0] value);
        logic [31:0] mixed;
        begin
            mixed = value ^ (value << 13);
            mixed = mixed ^ (mixed >> 17);
            mixed = mixed ^ (mixed << 5);
            hash32 = mixed;
        end
    endfunction

    function automatic logic [127:0] make_pattern(
        input logic [28:0] beat_addr,
        input logic [2:0] pattern,
        input logic [6:0] walk_bit
    );
        logic [31:0] byte_addr;
        logic [127:0] address_data;
        logic [127:0] walk_mask;
        begin
            byte_addr = {3'b000, beat_addr};
            address_data[31:0] = byte_addr;
            address_data[63:32] = byte_addr + 32'd4;
            address_data[95:64] = byte_addr + 32'd8;
            address_data[127:96] = byte_addr + 32'd12;
            walk_mask = 128'b1 << walk_bit;

            unique case (pattern)
                PATTERN_WALKING_ONE: begin
                    make_pattern = walk_mask;
                end
                PATTERN_WALKING_ZERO: begin
                    make_pattern = ~walk_mask;
                end
                PATTERN_ADDRESS: begin
                    make_pattern = address_data;
                end
                PATTERN_INVERSE_ADDRESS: begin
                    make_pattern = ~address_data;
                end
                default: begin
                    make_pattern[31:0] = hash32(byte_addr ^ 32'h243f_6a88);
                    make_pattern[63:32] = hash32((byte_addr + 32'd4) ^ 32'h85a3_08d3);
                    make_pattern[95:64] = hash32((byte_addr + 32'd8) ^ 32'h1319_8a2e);
                    make_pattern[127:96] = hash32((byte_addr + 32'd12) ^ 32'h0370_7344);
                end
            endcase
        end
    endfunction

    function automatic logic [7:0] burst_len_at(
        input logic [24:0] address_beat
    );
        logic [25:0] remaining_beats;
        logic [8:0] boundary_beats;
        logic [8:0] selected_beats;
        begin
            remaining_beats = BIST_END_ADDR[29:4]
                - {1'b0, address_beat};
            boundary_beats = 9'd256 - {1'b0, address_beat[7:0]};
            selected_beats = BURST_BEATS;

            if (remaining_beats < {17'd0, selected_beats}) begin
                selected_beats = remaining_beats[8:0];
            end
            if (boundary_beats < selected_beats) begin
                selected_beats = boundary_beats;
            end
            // Eight AXI LEN bits encode 1..256 beats as 0..255.
            burst_len_at = selected_beats[7:0] - 8'd1;
        end
    endfunction

    initial begin
        assert (BIST_APERTURE_BYTES != 0)
            else $fatal(1, "ddr3_bist aperture must be nonzero");
        assert (BIST_BASE_ADDR[3:0] == 4'b0000)
            else $fatal(1, "ddr3_bist base address must be 16-byte aligned");
        assert (BIST_APERTURE_BYTES[3:0] == 4'b0000)
            else $fatal(1, "ddr3_bist aperture must be a multiple of 16 bytes");
        assert ((BURST_BEATS >= 9'd1) && (BURST_BEATS <= 9'd256))
            else $fatal(1, "ddr3_bist BURST_BEATS must be in 1..256");
        assert (BIST_END_ADDR <= MIG_CAPACITY_BYTES)
            else $fatal(1, "ddr3_bist aperture exceeds the 512 MiB MIG range");
    end

    assign active_burst_beats = {1'b0, burst_len_q} + 9'd1;
    assign active_burst_bytes = {active_burst_beats, 4'b0000};
    assign next_addr_ext = {1'b0, current_addr_q}
        + {{17{1'b0}}, active_burst_bytes};

    assign write_beat_addr = current_addr_q
        + {17'd0, write_beat_q, 4'b0000};
    assign read_beat_addr = current_addr_q
        + {17'd0, read_beat_q, 4'b0000};

    // Write and read/compare phases are mutually exclusive, so one pattern
    // generator serves both paths instead of duplicating a wide hash network.
    assign pattern_beat_addr = (state_q == ST_WRITE_BURST)
        ? write_beat_addr : read_beat_addr;
    assign active_pattern_data = make_pattern(
        pattern_beat_addr,
        pattern_q,
        walk_bit_q
    );
    assign read_expected_data = active_pattern_data;
    assign read_expected_last = read_beat_q == burst_len_q;

    always_comb begin
        read_error_kind = ERROR_NONE;
        if (m_axi_rresp != 2'b00) begin
            read_error_kind = ERROR_RRESP;
        end else if (m_axi_rid != AXI_ID) begin
            read_error_kind = ERROR_RID;
        end else if (m_axi_rlast != read_expected_last) begin
            read_error_kind = ERROR_RLAST;
        end else if (m_axi_rdata != read_expected_data) begin
            read_error_kind = ERROR_DATA;
        end
    end

    assign read_beat_error = read_error_kind != ERROR_NONE;

    assign status_pattern = pattern_q;
    assign status_walk_bit = walk_bit_q;
    assign status_current_addr = current_addr_q;

    assign m_axi_awid = AXI_ID;
    assign m_axi_awaddr = current_addr_q;
    assign m_axi_awlen = burst_len_q;
    assign m_axi_awsize = 3'd4;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awlock = 1'b0;
    assign m_axi_awcache = 4'b0011;
    assign m_axi_awprot = 3'b000;
    assign m_axi_awqos = 4'b0000;
    assign m_axi_awvalid = awvalid_q;

    // Register write data before it enters the interconnect/MIG path.  Pattern
    // generation (especially the address hash) is intentionally kept out of
    // the same 100-MHz cycle as the AXI fabric write-data mux.
    assign m_axi_wdata = write_pattern_q;
    assign m_axi_wstrb = 16'hffff;
    assign m_axi_wlast = write_beat_q == burst_len_q;
    assign m_axi_wvalid = wvalid_q;
    assign m_axi_bready = state_q == ST_WRITE_RESPONSE;

    assign m_axi_arid = AXI_ID;
    assign m_axi_araddr = current_addr_q;
    assign m_axi_arlen = burst_len_q;
    assign m_axi_arsize = 3'd4;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arlock = 1'b0;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_arprot = 3'b000;
    assign m_axi_arqos = 4'b0000;
    assign m_axi_arvalid = arvalid_q;
    assign m_axi_rready = (state_q == ST_READ_DATA)
        || (state_q == ST_DRAIN_READ);

    always_ff @(posedge ui_clk) begin
        if (ui_reset) begin
            state_q <= ST_IDLE;
            start_q <= 1'b0;
            pattern_q <= PATTERN_WALKING_ONE;
            walk_bit_q <= '0;
            current_addr_q <= BIST_BASE_ADDR;
            burst_len_q <= '0;
            write_beat_q <= '0;
            read_beat_q <= '0;
            next_addr_q <= {1'b0, BIST_BASE_ADDR};
            awvalid_q <= 1'b0;
            wvalid_q <= 1'b0;
            arvalid_q <= 1'b0;
            read_burst_error_q <= 1'b0;
            write_pattern_q <= '0;

            status_busy <= 1'b0;
            status_done <= 1'b0;
            status_pass <= 1'b0;
            status_error <= 1'b0;
            first_error_kind <= ERROR_NONE;
            first_error_addr <= '0;
            first_error_expected <= '0;
            first_error_actual <= '0;
            first_error_resp <= 2'b00;
        end else begin
            start_q <= start;

            unique case (state_q)
                ST_IDLE: begin
                    awvalid_q <= 1'b0;
                    wvalid_q <= 1'b0;
                    arvalid_q <= 1'b0;

                    if (start && !start_q) begin
                        pattern_q <= PATTERN_WALKING_ONE;
                        walk_bit_q <= '0;
                        current_addr_q <= BIST_BASE_ADDR;
                        status_busy <= 1'b1;
                        status_done <= 1'b0;
                        status_pass <= 1'b0;
                        status_error <= 1'b0;
                        first_error_kind <= ERROR_NONE;
                        first_error_addr <= '0;
                        first_error_expected <= '0;
                        first_error_actual <= '0;
                        first_error_resp <= 2'b00;
                        state_q <= ST_CALCULATE_WRITE;
                    end
                end

                // Split burst sizing and next-address calculation across two
                // cycles.  Besides simplifying the control path, this keeps a
                // 29-bit add out of the pattern-transition enable path at
                // 100 MHz.
                ST_CALCULATE_WRITE: begin
                    burst_len_q <= burst_len_at(current_addr_q[28:4]);
                    state_q <= ST_PREPARE_WRITE;
                end

                ST_PREPARE_WRITE: begin
                    next_addr_q <= next_addr_ext;
                    write_beat_q <= '0;
                    write_pattern_q <= make_pattern(
                        current_addr_q,
                        pattern_q,
                        walk_bit_q
                    );
                    awvalid_q <= 1'b1;
                    wvalid_q <= 1'b1;
                    state_q <= ST_WRITE_BURST;
                end

                ST_WRITE_BURST: begin
                    if (awvalid_q && m_axi_awready) begin
                        awvalid_q <= 1'b0;
                    end

                    if (wvalid_q && m_axi_wready) begin
                        if (m_axi_wlast) begin
                            wvalid_q <= 1'b0;
                        end else begin
                            write_beat_q <= write_beat_q + 1'b1;
                            write_pattern_q <= make_pattern(
                                write_beat_addr + 29'd16,
                                pattern_q,
                                walk_bit_q
                            );
                        end
                    end

                    if ((!awvalid_q || m_axi_awready)
                        && (!wvalid_q || (m_axi_wready && m_axi_wlast))) begin
                        state_q <= ST_WRITE_RESPONSE;
                    end
                end

                ST_WRITE_RESPONSE: begin
                    if (m_axi_bvalid) begin
                        if ((m_axi_bresp != 2'b00) || (m_axi_bid != AXI_ID)) begin
                            status_busy <= 1'b0;
                            status_done <= 1'b1;
                            status_pass <= 1'b0;
                            status_error <= 1'b1;
                            first_error_kind <= (m_axi_bresp != 2'b00)
                                ? ERROR_BRESP : ERROR_BID;
                            first_error_addr <= current_addr_q;
                            first_error_expected <= '0;
                            first_error_actual <= '0;
                            first_error_resp <= m_axi_bresp;
                            state_q <= ST_IDLE;
                        end else if (next_addr_q == BIST_END_ADDR) begin
                            current_addr_q <= BIST_BASE_ADDR;
                            state_q <= ST_CALCULATE_READ;
                        end else begin
                            current_addr_q <= next_addr_q[28:0];
                            state_q <= ST_CALCULATE_WRITE;
                        end
                    end
                end

                ST_CALCULATE_READ: begin
                    burst_len_q <= burst_len_at(current_addr_q[28:4]);
                    state_q <= ST_PREPARE_READ;
                end

                ST_PREPARE_READ: begin
                    next_addr_q <= next_addr_ext;
                    read_beat_q <= '0;
                    read_burst_error_q <= 1'b0;
                    arvalid_q <= 1'b1;
                    state_q <= ST_READ_ADDRESS;
                end

                ST_READ_ADDRESS: begin
                    if (arvalid_q && m_axi_arready) begin
                        arvalid_q <= 1'b0;
                        state_q <= ST_READ_DATA;
                    end
                end

                ST_READ_DATA: begin
                    if (m_axi_rvalid) begin
                        if (read_beat_error && !status_error) begin
                            status_error <= 1'b1;
                            first_error_kind <= read_error_kind;
                            first_error_addr <= read_beat_addr;
                            first_error_expected <= read_expected_data;
                            first_error_actual <= m_axi_rdata;
                            first_error_resp <= m_axi_rresp;
                        end

                        if (read_beat_error) begin
                            read_burst_error_q <= 1'b1;
                        end

                        if (m_axi_rlast) begin
                            // Defer burst-completion decisions by one cycle.
                            // This registers the 128-bit data comparison before
                            // it can affect the address/pattern control path.
                            state_q <= ST_FINISH_READ_BURST;
                        end else if (read_expected_last) begin
                            // The expected final beat arrived without RLAST.
                            // Keep RREADY asserted until the malformed burst is
                            // drained so no accepted AXI transaction is abandoned.
                            state_q <= ST_DRAIN_READ;
                        end else begin
                            read_beat_q <= read_beat_q + 1'b1;
                        end
                    end
                end

                ST_FINISH_READ_BURST: begin
                            if (read_burst_error_q) begin
                                status_busy <= 1'b0;
                                status_done <= 1'b1;
                                status_pass <= 1'b0;
                                state_q <= ST_IDLE;
                            end else if (next_addr_q == BIST_END_ADDR) begin
                                current_addr_q <= BIST_BASE_ADDR;

                                unique case (pattern_q)
                                    PATTERN_WALKING_ONE: begin
                                        if (walk_bit_q == 7'd127) begin
                                            pattern_q <= PATTERN_WALKING_ZERO;
                                            walk_bit_q <= '0;
                                        end else begin
                                            walk_bit_q <= walk_bit_q + 1'b1;
                                        end
                                        state_q <= ST_CALCULATE_WRITE;
                                    end
                                    PATTERN_WALKING_ZERO: begin
                                        if (walk_bit_q == 7'd127) begin
                                            pattern_q <= PATTERN_ADDRESS;
                                            walk_bit_q <= '0;
                                        end else begin
                                            walk_bit_q <= walk_bit_q + 1'b1;
                                        end
                                        state_q <= ST_CALCULATE_WRITE;
                                    end
                                    PATTERN_ADDRESS: begin
                                        pattern_q <= PATTERN_INVERSE_ADDRESS;
                                        state_q <= ST_CALCULATE_WRITE;
                                    end
                                    PATTERN_INVERSE_ADDRESS: begin
                                        pattern_q <= PATTERN_PSEUDORANDOM;
                                        state_q <= ST_CALCULATE_WRITE;
                                    end
                                    default: begin
                                        status_busy <= 1'b0;
                                        status_done <= 1'b1;
                                        status_pass <= 1'b1;
                                        state_q <= ST_IDLE;
                                    end
                                endcase
                            end else begin
                                current_addr_q <= next_addr_q[28:0];
                                state_q <= ST_CALCULATE_READ;
                            end
                end

                ST_DRAIN_READ: begin
                    if (m_axi_rvalid && m_axi_rlast) begin
                        status_busy <= 1'b0;
                        status_done <= 1'b1;
                        status_pass <= 1'b0;
                        state_q <= ST_IDLE;
                    end
                end

                default: begin
                    state_q <= ST_IDLE;
                    status_busy <= 1'b0;
                    status_done <= 1'b1;
                    status_pass <= 1'b0;
                end
            endcase
        end
    end

endmodule
