// Minimal dual-clock AXI4-Stream payload FIFO.
//
// Only TVALID/TREADY and a generic payload cross this boundary. Callers pack
// any required stream metadata into TDATA, which keeps the CDC primitive
// reusable without adding optional AXI sideband logic outside the v2.0 scope.
//
// Both aresetn inputs are active-low and synchronous to their named clocks.
// Deassertion may occur in either order. A flush/reset request must eventually
// be applied to both domains; preserving queued data across a one-sided reset
// is intentionally not part of this primitive's contract.

module axis_async_fifo #(
    parameter integer DATA_WIDTH = 32,
    parameter integer DEPTH = 512
) (
    input logic s_axis_aclk,
    input logic s_axis_aresetn,

    input logic [DATA_WIDTH-1:0] s_axis_tdata,
    input logic s_axis_tvalid,
    output logic s_axis_tready,

    input logic m_axis_aclk,
    input logic m_axis_aresetn,

    output logic [DATA_WIDTH-1:0] m_axis_tdata,
    output logic m_axis_tvalid,
    input logic m_axis_tready
);

    localparam integer ADDRESS_WIDTH = $clog2(DEPTH);
    localparam integer POINTER_WIDTH = ADDRESS_WIDTH + 1;

    (* ram_style = "block" *)
    logic [DATA_WIDTH-1:0] payload_memory [0:DEPTH-1];

    logic [POINTER_WIDTH-1:0] write_binary_q;
    logic [POINTER_WIDTH-1:0] write_binary_next;
    logic [POINTER_WIDTH-1:0] write_gray_q;
    logic [POINTER_WIDTH-1:0] write_gray_next;
    logic write_full_q;
    logic write_full_next;
    logic write_push;

    logic [POINTER_WIDTH-1:0] read_binary_q;
    logic [POINTER_WIDTH-1:0] read_binary_incremented;
    logic [POINTER_WIDTH-1:0] read_gray_q;
    logic [POINTER_WIDTH-1:0] read_gray_incremented;
    logic read_empty;
    logic read_next_empty;
    logic read_pop;
    logic memory_read_enable;
    logic [ADDRESS_WIDTH-1:0] memory_read_address;

    logic [DATA_WIDTH-1:0] output_data_q;
    logic output_valid_q;

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [POINTER_WIDTH-1:0] read_gray_sync1_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [POINTER_WIDTH-1:0] read_gray_sync2_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [POINTER_WIDTH-1:0] write_gray_sync1_q;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [POINTER_WIDTH-1:0] write_gray_sync2_q;

    logic [POINTER_WIDTH-1:0] read_gray_full_compare;

    initial begin
        assert (DATA_WIDTH > 0)
            else $fatal(1, "axis_async_fifo DATA_WIDTH must be positive");
        assert (DEPTH >= 4)
            else $fatal(1, "axis_async_fifo DEPTH must be at least four");
        assert ((DEPTH & (DEPTH - 1)) == 0)
            else $fatal(1, "axis_async_fifo DEPTH must be a power of two");
    end

    function automatic logic [POINTER_WIDTH-1:0] binary_to_gray(
        input logic [POINTER_WIDTH-1:0] binary_value
    );
        return (binary_value >> 1) ^ binary_value;
    endfunction

    assign s_axis_tready = !write_full_q;
    assign write_push = s_axis_tvalid && s_axis_tready;

    always_comb begin
        write_binary_next = write_binary_q + write_push;
        write_gray_next = binary_to_gray(write_binary_next);

        // A full FIFO is one complete binary-pointer wrap ahead of the
        // synchronized read pointer. In Gray code this is represented by
        // complementing the two most-significant bits.
        read_gray_full_compare = read_gray_sync2_q;
        read_gray_full_compare[POINTER_WIDTH-1 -: 2] =
            ~read_gray_sync2_q[POINTER_WIDTH-1 -: 2];
        write_full_next = write_gray_next == read_gray_full_compare;
    end

    // The write port is the only writer. Memory contents are deliberately not
    // reset so Vivado can infer a true simple-dual-port block RAM.
    always_ff @(posedge s_axis_aclk) begin
        if (s_axis_aresetn && write_push) begin
            payload_memory[write_binary_q[ADDRESS_WIDTH-1:0]] <=
                s_axis_tdata;
        end
    end

    always_ff @(posedge s_axis_aclk) begin
        if (!s_axis_aresetn) begin
            write_binary_q <= {POINTER_WIDTH{1'b0}};
            write_gray_q <= {POINTER_WIDTH{1'b0}};
            write_full_q <= 1'b0;
        end else begin
            write_binary_q <= write_binary_next;
            write_gray_q <= write_gray_next;
            write_full_q <= write_full_next;
        end
    end

    // Read pointer synchronization into the write domain.
    always_ff @(posedge s_axis_aclk) begin
        if (!s_axis_aresetn) begin
            read_gray_sync1_q <= {POINTER_WIDTH{1'b0}};
            read_gray_sync2_q <= {POINTER_WIDTH{1'b0}};
        end else begin
            read_gray_sync1_q <= read_gray_q;
            read_gray_sync2_q <= read_gray_sync1_q;
        end
    end

    assign m_axis_tdata = output_data_q;
    assign m_axis_tvalid = output_valid_q;
    assign read_pop = m_axis_tvalid && m_axis_tready;

    assign read_empty = read_gray_q == write_gray_sync2_q;
    assign read_binary_incremented = read_binary_q + 1'b1;
    assign read_gray_incremented = binary_to_gray(read_binary_incremented);
    assign read_next_empty =
        read_gray_incremented == write_gray_sync2_q;
    assign memory_read_enable =
        (!output_valid_q && !read_empty)
        || (read_pop && !read_next_empty);
    assign memory_read_address = output_valid_q
        ? read_binary_incremented[ADDRESS_WIDTH-1:0]
        : read_binary_q[ADDRESS_WIDTH-1:0];

    // Keep the RAM read in its own clocked process so Vivado recognizes the
    // native simple-dual-port block-RAM template with independent clocks.
    always_ff @(posedge m_axis_aclk) begin
        if (m_axis_aresetn && memory_read_enable) begin
            output_data_q <= payload_memory[memory_read_address];
        end
    end

    // The output register mirrors the current read-pointer location without
    // releasing that RAM slot. The pointer advances only when the AXI transfer
    // is accepted, so DEPTH remains the exact externally visible capacity.
    // Loading the next address on the same edge as a pop sustains one transfer
    // per read clock while retaining a synchronous BRAM read template.
    always_ff @(posedge m_axis_aclk) begin
        if (!m_axis_aresetn) begin
            read_binary_q <= {POINTER_WIDTH{1'b0}};
            read_gray_q <= {POINTER_WIDTH{1'b0}};
            output_valid_q <= 1'b0;
        end else if (!output_valid_q) begin
            if (!read_empty) begin
                output_valid_q <= 1'b1;
            end
        end else if (read_pop) begin
            read_binary_q <= read_binary_incremented;
            read_gray_q <= read_gray_incremented;

            if (read_next_empty) begin
                output_valid_q <= 1'b0;
            end else begin
                output_valid_q <= 1'b1;
            end
        end
    end

    // Write pointer synchronization into the read domain.
    always_ff @(posedge m_axis_aclk) begin
        if (!m_axis_aresetn) begin
            write_gray_sync1_q <= {POINTER_WIDTH{1'b0}};
            write_gray_sync2_q <= {POINTER_WIDTH{1'b0}};
        end else begin
            write_gray_sync1_q <= write_gray_q;
            write_gray_sync2_q <= write_gray_sync1_q;
        end
    end

endmodule
