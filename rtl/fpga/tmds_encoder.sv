// Single-lane DVI/HDMI TMDS encoder.
//
// One instance encodes one 8-bit video channel at the pixel clock. During
// blanking it emits one of the four TMDS control symbols and resets running
// disparity. The registered output has one pixel-clock latency.
//
// For the blue lane, connect control_data as {vsync, hsync}; red and green use
// 2'b00. tmds_data[0] is the first bit to be serialized.

module tmds_encoder (
    input logic pix_clk,
    input logic pix_reset,

    input logic [7:0] video_data,
    input logic [1:0] control_data,
    input logic video_enable,

    output logic [9:0] tmds_data
);

    localparam logic [9:0] CONTROL_00 = 10'b1101010100;
    localparam logic [9:0] CONTROL_01 = 10'b0010101011;
    localparam logic [9:0] CONTROL_10 = 10'b0101010100;
    localparam logic [9:0] CONTROL_11 = 10'b1010101011;

    logic [3:0] video_ones;
    logic use_xnor;
    logic [8:0] transition_word;
    logic [3:0] transition_ones;
    logic signed [5:0] transition_balance;

    logic [9:0] video_code;
    logic [9:0] control_code;
    logic signed [5:0] disparity_q;
    logic signed [5:0] disparity_next;

    always_comb begin
        video_ones =
            {3'b000, video_data[0]} +
            {3'b000, video_data[1]} +
            {3'b000, video_data[2]} +
            {3'b000, video_data[3]} +
            {3'b000, video_data[4]} +
            {3'b000, video_data[5]} +
            {3'b000, video_data[6]} +
            {3'b000, video_data[7]};

        use_xnor = (video_ones > 4) || ((video_ones == 4) && !video_data[0]);

        transition_word = '0;
        transition_word[0] = video_data[0];

        for (integer bit_index = 1; bit_index < 8; bit_index++) begin
            if (use_xnor) begin
                transition_word[bit_index] =
                    ~(transition_word[bit_index - 1] ^ video_data[bit_index]);
            end else begin
                transition_word[bit_index] =
                    transition_word[bit_index - 1] ^ video_data[bit_index];
            end
        end

        transition_word[8] = !use_xnor;
    end

    always_comb begin
        transition_ones =
            {3'b000, transition_word[0]} +
            {3'b000, transition_word[1]} +
            {3'b000, transition_word[2]} +
            {3'b000, transition_word[3]} +
            {3'b000, transition_word[4]} +
            {3'b000, transition_word[5]} +
            {3'b000, transition_word[6]} +
            {3'b000, transition_word[7]};

        // Signed difference between ones and zeros in transition_word[7:0].
        transition_balance = $signed({1'b0, transition_ones, 1'b0}) - 6'sd8;
    end

    always_comb begin
        video_code = '0;
        video_code[8] = transition_word[8];
        disparity_next = disparity_q;

        if ((disparity_q == 0) || (transition_balance == 0)) begin
            video_code[9] = !transition_word[8];

            if (transition_word[8]) begin
                video_code[7:0] = transition_word[7:0];
                disparity_next = disparity_q + transition_balance;
            end else begin
                video_code[7:0] = ~transition_word[7:0];
                disparity_next = disparity_q - transition_balance;
            end
        end else if (((disparity_q > 0) && (transition_balance > 0)) || ((disparity_q < 0) && (transition_balance < 0))) begin
            video_code[9] = 1'b1;
            video_code[7:0] = ~transition_word[7:0];
            disparity_next = disparity_q - transition_balance + (transition_word[8] ? 6'sd2 : 6'sd0);
        end else begin
            video_code[9] = 1'b0;
            video_code[7:0] = transition_word[7:0];
            disparity_next = disparity_q + transition_balance - (transition_word[8] ? 6'sd0 : 6'sd2);
        end
    end

    always_comb begin
        case (control_data)
            2'b00: control_code = CONTROL_00;
            2'b01: control_code = CONTROL_01;
            2'b10: control_code = CONTROL_10;
            default: control_code = CONTROL_11;
        endcase
    end

    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            tmds_data <= '0;
            disparity_q <= '0;
        end else if (video_enable) begin
            tmds_data <= video_code;
            disparity_q <= disparity_next;
        end else begin
            tmds_data <= control_code;
            disparity_q <= '0;
        end
    end

endmodule
