`timescale 1ns/1ps

module tmds_encoder_tb;

    localparam time CLK_PERIOD = 10ns;

    logic pix_clk;
    logic pix_reset;
    logic [7:0] video_data;
    logic [1:0] control_data;
    logic video_enable;
    logic [9:0] tmds_data;

    integer model_disparity;
    integer minimum_disparity;
    integer maximum_disparity;
    integer checked_symbols;

    tmds_encoder dut (
        .pix_clk,
        .pix_reset,
        .video_data,
        .control_data,
        .video_enable,
        .tmds_data
    );

    always #(CLK_PERIOD / 2) pix_clk = !pix_clk;

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $fatal(1, "CHECK FAILED: %s", message);
        end
    endtask

    function automatic integer count_ones_8(input logic [7:0] value);
        integer result;
        begin
            result = 0;
            for (integer bit_index = 0; bit_index < 8; bit_index++) begin
                result += value[bit_index];
            end
            return result;
        end
    endfunction

    function automatic integer count_ones_10(input logic [9:0] value);
        integer result;
        begin
            result = 0;
            for (integer bit_index = 0; bit_index < 10; bit_index++) begin
                result += value[bit_index];
            end
            return result;
        end
    endfunction

    function automatic logic [9:0] expected_control(input logic [1:0] control);
        case (control)
            2'b00: return 10'b1101010100;
            2'b01: return 10'b0010101011;
            2'b10: return 10'b0101010100;
            default: return 10'b1010101011;
        endcase
    endfunction

    function automatic logic [9:0] expected_video(
        input logic [7:0] data,
        input integer running_disparity
    );
        logic [8:0] transition_word;
        logic use_xnor;
        integer data_ones;
        integer transition_ones;
        integer transition_balance;
        begin
            data_ones = count_ones_8(data);
            use_xnor = (data_ones > 4) || ((data_ones == 4) && !data[0]);

            transition_word = '0;
            transition_word[0] = data[0];
            for (integer bit_index = 1; bit_index < 8; bit_index++) begin
                transition_word[bit_index] = use_xnor ?
                    ~(transition_word[bit_index - 1] ^ data[bit_index]) :
                    (transition_word[bit_index - 1] ^ data[bit_index]);
            end
            transition_word[8] = !use_xnor;

            transition_ones = count_ones_8(transition_word[7:0]);
            transition_balance = (2 * transition_ones) - 8;

            expected_video[8] = transition_word[8];
            if ((running_disparity == 0) || (transition_balance == 0)) begin
                expected_video[9] = !transition_word[8];
                expected_video[7:0] = transition_word[8] ?
                    transition_word[7:0] : ~transition_word[7:0];
            end else if (
                ((running_disparity > 0) && (transition_balance > 0)) ||
                ((running_disparity < 0) && (transition_balance < 0))
            ) begin
                expected_video[9] = 1'b1;
                expected_video[7:0] = ~transition_word[7:0];
            end else begin
                expected_video[9] = 1'b0;
                expected_video[7:0] = transition_word[7:0];
            end
        end
    endfunction

    task automatic drive_and_check(
        input logic enable,
        input logic [7:0] data,
        input logic [1:0] control
    );
        logic [9:0] expected_symbol;
        integer symbol_disparity;
        begin
            @(negedge pix_clk);
            video_enable = enable;
            video_data = data;
            control_data = control;

            expected_symbol = enable ?
                expected_video(data, model_disparity) :
                expected_control(control);

            @(posedge pix_clk);
            #1ps;
            check(tmds_data == expected_symbol, "TMDS symbol mismatch");

            if (enable) begin
                symbol_disparity = (2 * count_ones_10(expected_symbol)) - 10;
                model_disparity += symbol_disparity;
            end else begin
                model_disparity = 0;
            end

            check(
                dut.disparity_q == model_disparity[5:0],
                "running disparity mismatch"
            );

            if (model_disparity < minimum_disparity) begin
                minimum_disparity = model_disparity;
            end
            if (model_disparity > maximum_disparity) begin
                maximum_disparity = model_disparity;
            end
            checked_symbols++;
        end
    endtask

    initial begin
        pix_clk = 1'b0;
        pix_reset = 1'b1;
        video_data = '0;
        control_data = '0;
        video_enable = 1'b0;
        model_disparity = 0;
        minimum_disparity = 0;
        maximum_disparity = 0;
        checked_symbols = 0;

        repeat (2) @(posedge pix_clk);
        #1ps;
        check(tmds_data == 0, "TMDS output was not zero during reset");
        check(dut.disparity_q == 0, "disparity was not zero during reset");

        @(negedge pix_clk);
        pix_reset = 1'b0;

        // Check the four fixed blanking symbols and their bit ordering.
        for (integer control = 0; control < 4; control++) begin
            drive_and_check(1'b0, 8'hA5, 2'(control));
        end

        // Encode every possible byte from a known zero-disparity state.
        for (integer data = 0; data < 256; data++) begin
            drive_and_check(1'b0, 8'h00, 2'b00);
            drive_and_check(1'b1, 8'(data), 2'b00);
        end

        // Exercise continuous active-video history in both byte orders.
        for (integer data = 0; data < 256; data++) begin
            drive_and_check(1'b1, 8'(data), 2'b00);
        end
        for (integer data = 255; data >= 0; data--) begin
            drive_and_check(1'b1, 8'(data), 2'b00);
        end

        // Long deterministic sequence drives positive, negative, and zero
        // disparity histories without duplicating the DUT state equation.
        for (
            integer sample_index = 0;
            sample_index < 4096;
            sample_index++
        ) begin
            if ((sample_index % 257) == 256) begin
                drive_and_check(1'b0, 8'h00, 2'(sample_index));
            end else begin
                drive_and_check(1'b1, 8'((sample_index * 73) + 19), 2'b00);
            end
        end

        // A synchronous reset must clear both the registered symbol and history.
        @(negedge pix_clk);
        pix_reset = 1'b1;
        video_enable = 1'b1;
        video_data = 8'hFF;
        @(posedge pix_clk);
        #1ps;
        model_disparity = 0;
        check(tmds_data == 0, "TMDS output was not cleared by reset");
        check(dut.disparity_q == 0, "reset did not clear disparity");

        @(negedge pix_clk);
        pix_reset = 1'b0;
        drive_and_check(1'b0, 8'h00, 2'b00);

        $display(
            "tmds_encoder_tb: PASS (%0d symbols, disparity range %0d..%0d)",
            checked_symbols,
            minimum_disparity,
            maximum_disparity
        );
        $finish;
    end

endmodule
