`timescale 1ns/1ps

module tmds_serializer_tb;

    localparam time PIX_CLK_PERIOD = 10ns;
    localparam time TMDS_CLK_PERIOD = 2ns;

    logic pix_clk;
    logic tmds_clk_5x;
    logic pix_reset;
    logic [9:0] tmds_word;
    logic tmds_p;
    logic tmds_n;

    tmds_serializer dut (
        .pix_clk,
        .tmds_clk_5x,
        .pix_reset,
        .tmds_word,
        .tmds_p,
        .tmds_n
    );

    always #(PIX_CLK_PERIOD / 2) pix_clk = !pix_clk;
    always #(TMDS_CLK_PERIOD / 2) tmds_clk_5x = !tmds_clk_5x;

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $fatal(1, "CHECK FAILED: %s", message);
        end
    endtask

    task automatic capture_word(output logic [9:0] captured_word);
        begin
            // With the phase-aligned 1:5 clocks, D1 is presented on the final
            // falling CLK edge before the next rising CLKDIV edge.
            @(negedge pix_clk);
            repeat (2) @(negedge tmds_clk_5x);
            #1ps;
            captured_word[0] = tmds_p;
            check(tmds_n == !tmds_p, "differential outputs were not complementary");

            for (integer bit_index = 1; bit_index < 10; bit_index++) begin
                if (bit_index[0]) begin
                    @(posedge tmds_clk_5x);
                end else begin
                    @(negedge tmds_clk_5x);
                end
                #1ps;
                captured_word[bit_index] = tmds_p;
                check(
                    tmds_n == !tmds_p,
                    "differential outputs were not complementary"
                );
            end
        end
    endtask

    task automatic check_repeating_word(input logic [9:0] expected_word);
        logic [9:0] captured_word;
        begin
            @(negedge pix_clk);
            tmds_word = expected_word;

            // Allow the primitive's input and output pipeline to fill, then
            // capture one complete word from a known CLKDIV boundary.
            capture_word(captured_word);
            capture_word(captured_word);
            capture_word(captured_word);

            $display(
                "serializer capture: expected=%010b observed=%010b",
                expected_word,
                captured_word
            );
            check(captured_word == expected_word, "serialized bit order mismatch");
        end
    endtask

    initial begin
        pix_clk = 1'b0;
        tmds_clk_5x = 1'b0;
        pix_reset = 1'b1;
        tmds_word = '0;

        // The Xilinx global simulation reset is active for the first 100 ns.
        #120ns;
        @(negedge pix_clk);
        pix_reset = 1'b0;

        check_repeating_word(10'b1011000110);
        check_repeating_word(10'b0100111001);
        check_repeating_word(10'b1111100000);

        @(negedge pix_clk);
        pix_reset = 1'b1;
        @(posedge pix_clk);
        #1ps;
        check(tmds_p == 1'b0, "reset did not clear the serialized output");
        check(tmds_n == 1'b1, "reset did not clear the complementary output");

        $display("tmds_serializer_tb: PASS");
        $finish;
    end

endmodule
