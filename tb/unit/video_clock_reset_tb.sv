`timescale 1ns/1ps

module video_clock_reset_tb;

    localparam time CLK_50M_PERIOD = 20ns;
    localparam integer RELEASE_STAGES = 4;
    localparam integer REQUEST_SYNC_STAGES = 2;

    logic clk_50m;
    logic reset_async;
    logic pix_clk;
    logic tmds_clk_5x;
    logic pix_reset;
    integer tmds_edge_count;

    video_clock_reset dut (
        .clk_50m,
        .reset_async,
        .pix_clk,
        .tmds_clk_5x,
        .pix_reset
    );

    always #(CLK_50M_PERIOD / 2) clk_50m = !clk_50m;
    always @(posedge tmds_clk_5x) tmds_edge_count <= tmds_edge_count + 1;

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $fatal(1, "CHECK FAILED: %s", message);
        end
    endtask

    task automatic check_qualified_release;
        @(posedge dut.mmcm_locked);
        #1ps;
        check(pix_reset, "pixel reset released with raw MMCM lock");

        for (integer edge_index = 1;
            edge_index <= REQUEST_SYNC_STAGES + RELEASE_STAGES;
            edge_index++) begin
            @(posedge pix_clk);
            #1ps;
            if (edge_index < REQUEST_SYNC_STAGES + RELEASE_STAGES) begin
                check(pix_reset, "pixel reset released before lock qualification completed");
            end else begin
                check(!pix_reset, "pixel reset did not release after lock qualification");
            end
        end
    endtask

    initial begin
        integer edge_count_start;

        clk_50m = 1'b0;
        reset_async = 1'b1;
        tmds_edge_count = 0;
        #1ps;
        check(pix_reset, "pixel reset was not asserted at startup");

        // Normal Clocking Wizard startup and lock acquisition.
        #3ns;
        reset_async = 1'b0;
        check_qualified_release();

        // The behavioral clock stub preserves the required exact 5:1 clock
        // relationship used by the serializer interface.
        @(negedge pix_clk);
        #1ps;
        edge_count_start = tmds_edge_count;
        repeat (10) @(negedge pix_clk);
        #1ps;
        check(
            (tmds_edge_count - edge_count_start) == 50,
            "serializer clock did not maintain the 5:1 ratio"
        );

        // MMCM lock loss is captured immediately, but functional reset changes
        // only on a pixel-clock edge and then requires fresh qualification.
        #3ns;
        dut.u_video_clk_wiz.force_lock_loss = 1'b1;
        #1ps;
        check(!pix_reset, "lock loss asserted functional reset asynchronously");

        @(posedge pix_clk);
        #1ps;
        check(pix_reset, "lock loss did not assert pixel reset on a clock edge");

        @(posedge clk_50m);
        #1ps;
        dut.u_video_clk_wiz.force_lock_loss = 1'b0;
        check_qualified_release();

        // An external asynchronous request resets both the Clocking Wizard and
        // its downstream domains. Releasing it must repeat lock qualification.
        #3ns;
        reset_async = 1'b1;
        #1ps;
        check(!pix_reset, "external request asserted functional reset asynchronously");
        check(!dut.mmcm_locked, "Clocking Wizard remained locked while reset was asserted");

        @(posedge pix_clk);
        #1ps;
        check(pix_reset, "external request did not assert pixel reset on a clock edge");

        #3ns;
        reset_async = 1'b0;
        check_qualified_release();

        $display("video_clock_reset_tb: PASS");
        $finish;
    end

endmodule
