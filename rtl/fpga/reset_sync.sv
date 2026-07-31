// Per-clock-domain reset conditioner.
//
// reset_async asserts reset_out asynchronously so a stopped or unstable clock
// cannot leave downstream board logic enabled. Deassertion passes through four
// destination-clock registers by default and therefore occurs only on a
// rising edge of clk.

module reset_sync #(
    parameter integer RELEASE_STAGES = 4
) (
    input logic clk,
    input logic reset_async,
    output logic reset_out
);

    // Keep the synchronizer as discrete, closely placed flip-flops. These
    // attributes are understood by Vivado and ignored by generic simulators.
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [RELEASE_STAGES-1:0] release_pipe_q;

    initial begin
        assert (RELEASE_STAGES >= 4)
            else $fatal(1, "reset_sync RELEASE_STAGES must be at least 4");
    end

    assign reset_out = release_pipe_q[RELEASE_STAGES-1];

    always_ff @(posedge clk or posedge reset_async) begin
        if (reset_async) begin
            release_pipe_q <= '1;
        end else begin
            release_pipe_q <= release_pipe_q << 1;
        end
    end

endmodule
