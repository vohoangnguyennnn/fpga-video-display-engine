`timescale 1ns/1ps

module reset_sync_tb;

    localparam integer RELEASE_STAGES = 4;
    localparam integer REQUEST_SYNC_STAGES = 2;
    localparam time CLK_PERIOD = 10ns;

    logic clk;
    logic reset_async;
    logic reset_out;

    reset_sync #(
        .RELEASE_STAGES(RELEASE_STAGES)
    ) dut (
        .clk,
        .reset_async,
        .reset_out
    );

    always #(CLK_PERIOD / 2) clk = !clk;

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $fatal(1, "CHECK FAILED: %s", message);
        end
    endtask

    task automatic check_qualified_release;
        localparam integer QUALIFICATION_EDGES =
            REQUEST_SYNC_STAGES + RELEASE_STAGES;

        for (integer edge_index = 1; edge_index <= QUALIFICATION_EDGES; edge_index++) begin
            @(posedge clk);
            #1ps;

            if (edge_index < QUALIFICATION_EDGES) begin
                check(reset_out, "reset released before request synchronization and hold completed");
            end else begin
                check(!reset_out, "reset did not release after the qualified hold interval");
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        reset_async = 1'b1;
        #1ps;
        check(reset_out, "reset was not asserted at startup");

        // Release away from a clock edge. The output remains asserted while
        // the request deassertion is synchronized and for four further edges.
        #2ns;
        reset_async = 1'b0;
        #1ns;
        check(reset_out, "reset deasserted asynchronously");
        check_qualified_release();

        // The functional reset must assert only on a destination-clock edge,
        // even though the request synchronizer captures assertion immediately.
        #(CLK_PERIOD / 4);
        reset_async = 1'b1;
        #1ps;
        check(!reset_out, "functional reset asserted asynchronously");

        @(posedge clk);
        #1ps;
        check(reset_out, "functional reset did not assert on the next clock edge");

        // Even a request shorter than one clock period is retained by the
        // asynchronously asserted request synchronizer.
        #1ns;
        reset_async = 1'b0;
        #1ns;
        check(reset_out, "short reset request was not retained");
        check_qualified_release();

        $display("reset_sync_tb: PASS");
        $finish;
    end

endmodule
