// BRAM-backed, stall-aware payload alignment FIFO.
//
// The grayscale fork pushes one payload for every token accepted by the
// window path. The mode-mux join pops one payload with each matched Sobel
// result. The default depth covers the centered-window look-ahead plus the
// current registered arithmetic path without introducing a no-stall bubble.

import video_pkg::video_payload_t;

module stream_align_delay #(
    parameter integer MAX_WIDTH = 1280,
    parameter integer ALIGNMENT_DEPTH = MAX_WIDTH + 7
) (
    input logic aclk,
    input logic aresetn,

    input video_payload_t s_axis_payload,
    input logic s_axis_tvalid,
    output logic s_axis_tready,

    output video_payload_t m_axis_payload,
    output logic m_axis_tvalid,
    input logic m_axis_tready
);

    localparam integer ADDRESS_WIDTH = $clog2(ALIGNMENT_DEPTH);
    localparam integer COUNT_WIDTH = $clog2(ALIGNMENT_DEPTH + 1);
    localparam integer LAST_ADDRESS = ALIGNMENT_DEPTH - 1;

    localparam logic [ADDRESS_WIDTH-1:0] LAST_ADDRESS_VALUE = LAST_ADDRESS[ADDRESS_WIDTH-1:0];
    localparam logic [COUNT_WIDTH-1:0] ALIGNMENT_DEPTH_VALUE = ALIGNMENT_DEPTH[COUNT_WIDTH-1:0];
    localparam logic [ADDRESS_WIDTH-1:0] ADDRESS_ONE = {{(ADDRESS_WIDTH - 1){1'b0}}, 1'b1};
    localparam logic [COUNT_WIDTH-1:0] COUNT_ONE = {{(COUNT_WIDTH - 1){1'b0}}, 1'b1};

    video_payload_t payload_memory [0:ALIGNMENT_DEPTH-1];

    logic [ADDRESS_WIDTH-1:0] write_pointer_q;
    logic [ADDRESS_WIDTH-1:0] read_pointer_q;
    logic [COUNT_WIDTH-1:0] memory_count_q;
    logic [COUNT_WIDTH-1:0] occupancy_q;

    video_payload_t output_payload_q;
    logic output_valid_q;

    logic push;
    logic pop;
    logic prefetch;
    logic output_slot_ready;
    logic fifo_full;

    initial begin
        assert ((MAX_WIDTH >= 3) && (MAX_WIDTH <= 65535))
            else $fatal(1, "MAX_WIDTH must be in the range 3..65535");
        assert (ALIGNMENT_DEPTH >= (MAX_WIDTH + 7))
            else $fatal(1, "ALIGNMENT_DEPTH must cover MAX_WIDTH plus seven tokens");
        assert ($bits(video_payload_t) == 36)
            else $fatal(1, "video_payload_t must remain 36 bits");
    end

    assign fifo_full = occupancy_q == ALIGNMENT_DEPTH_VALUE;
    assign pop = output_valid_q && m_axis_tready;

    // A simultaneous pop releases one slot immediately, preserving one-token
    // throughput even when the FIFO is full.
    assign s_axis_tready = !fifo_full || pop;
    assign push = s_axis_tvalid && s_axis_tready;

    assign output_slot_ready = !output_valid_q || m_axis_tready;
    assign prefetch = output_slot_ready && (memory_count_q != {COUNT_WIDTH{1'b0}});

    assign m_axis_payload = output_payload_q;
    assign m_axis_tvalid = output_valid_q;

    // Separate synchronous read and write processes form the simple-dual-port
    // BRAM inference template. Memory contents are intentionally not reset.
    always_ff @(posedge aclk) begin
        if (aresetn && push) begin
            payload_memory[write_pointer_q] <= s_axis_payload;
        end
    end

    always_ff @(posedge aclk) begin
        if (aresetn && prefetch) begin
            output_payload_q <= payload_memory[read_pointer_q];
        end
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            write_pointer_q <= {ADDRESS_WIDTH{1'b0}};
            read_pointer_q <= {ADDRESS_WIDTH{1'b0}};
            memory_count_q <= {COUNT_WIDTH{1'b0}};
            occupancy_q <= {COUNT_WIDTH{1'b0}};
            output_valid_q <= 1'b0;
        end else begin
            if (push) begin
                if (write_pointer_q == LAST_ADDRESS_VALUE) begin
                    write_pointer_q <= {ADDRESS_WIDTH{1'b0}};
                end else begin
                    write_pointer_q <= write_pointer_q + ADDRESS_ONE;
                end
            end

            if (prefetch) begin
                if (read_pointer_q == LAST_ADDRESS_VALUE) begin
                    read_pointer_q <= {ADDRESS_WIDTH{1'b0}};
                end else begin
                    read_pointer_q <= read_pointer_q + ADDRESS_ONE;
                end
            end

            case ({push, prefetch})
                2'b10: begin
                    memory_count_q <= memory_count_q + COUNT_ONE;
                end
                2'b01: begin
                    memory_count_q <= memory_count_q - COUNT_ONE;
                end
                default: begin
                    memory_count_q <= memory_count_q;
                end
            endcase

            case ({push, pop})
                2'b10: begin
                    occupancy_q <= occupancy_q + COUNT_ONE;
                end
                2'b01: begin
                    occupancy_q <= occupancy_q - COUNT_ONE;
                end
                default: begin
                    occupancy_q <= occupancy_q;
                end
            endcase

            if (output_slot_ready) begin
                output_valid_q <= prefetch;
            end
        end
    end

endmodule
