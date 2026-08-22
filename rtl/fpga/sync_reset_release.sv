// Destination-clock reset release for an already-synchronous request.
//
// Unlike reset_sync, this block has no asynchronous control pin.  Use it
// after an external status level has crossed through a conventional two-flop
// synchronizer, or directly for reset requests generated in clk.  Assertion
// occurs on the next clk edge and deassertion is delayed for RELEASE_STAGES
// clean edges.  Functional logic therefore never sees an asynchronous reset
// transition or combinational CDC path.

module sync_reset_release #(
    parameter integer RELEASE_STAGES = 4
) (
    input  logic clk,
    input  logic reset_request,
    output logic reset_out
);

    (* SHREG_EXTRACT = "NO" *)
    logic [RELEASE_STAGES-1:0] release_pipe_q;

    initial begin
        release_pipe_q = '1;

        assert (RELEASE_STAGES >= 2)
            else $fatal(1,"sync_reset_release RELEASE_STAGES must be at least 2");
    end

    assign reset_out = release_pipe_q[RELEASE_STAGES-1];

    always_ff @(posedge clk) begin
        if (reset_request) begin
            release_pipe_q <= '1;
        end else begin
            release_pipe_q <= release_pipe_q << 1;
        end
    end

endmodule
