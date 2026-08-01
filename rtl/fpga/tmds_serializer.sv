// Artix-7 10:1 DDR TMDS serializer for one differential lane.
//
// The parallel word is loaded in the pixel-clock domain and serialized by a
// phase-related 5x clock. tmds_word[0] is transmitted first. DATA_WIDTH=10
// requires the documented OSERDESE2 master/slave width-expansion connection.

module tmds_serializer (
    input logic pix_clk,
    input logic tmds_clk_5x,
    input logic pix_reset,
    input logic tmds_reset,

    input logic [9:0] tmds_word,

    output logic tmds_p,
    output logic tmds_n
);

    logic serializer_reset;
    logic cascade_data_1;
    logic cascade_data_2;
    logic serial_data;

    // OSERDESE2 internally retimes RST into both clock domains. Keeping reset
    // asserted until both external domain conditioners release also guarantees
    // a pulse longer than one CLKDIV cycle.
    assign serializer_reset = pix_reset || tmds_reset;

    OSERDESE2 #(
        .DATA_RATE_OQ("DDR"),
        .DATA_RATE_TQ("SDR"),
        .DATA_WIDTH(10),
        .INIT_OQ(1'b0),
        .INIT_TQ(1'b0),
        .SERDES_MODE("MASTER"),
        .SRVAL_OQ(1'b0),
        .SRVAL_TQ(1'b0),
        .TBYTE_CTL("FALSE"),
        .TBYTE_SRC("FALSE"),
        .TRISTATE_WIDTH(1)
    ) u_oserdes_master (
        .OFB(),
        .OQ(serial_data),
        .SHIFTOUT1(),
        .SHIFTOUT2(),
        .TBYTEOUT(),
        .TFB(),
        .TQ(),

        .CLK(tmds_clk_5x),
        .CLKDIV(pix_clk),
        .D1(tmds_word[0]),
        .D2(tmds_word[1]),
        .D3(tmds_word[2]),
        .D4(tmds_word[3]),
        .D5(tmds_word[4]),
        .D6(tmds_word[5]),
        .D7(tmds_word[6]),
        .D8(tmds_word[7]),
        .OCE(1'b1),
        .RST(serializer_reset),
        .SHIFTIN1(cascade_data_1),
        .SHIFTIN2(cascade_data_2),
        .T1(1'b0),
        .T2(1'b0),
        .T3(1'b0),
        .T4(1'b0),
        .TBYTEIN(1'b0),
        .TCE(1'b0)
    );

    OSERDESE2 #(
        .DATA_RATE_OQ("DDR"),
        .DATA_RATE_TQ("SDR"),
        .DATA_WIDTH(10),
        .INIT_OQ(1'b0),
        .INIT_TQ(1'b0),
        .SERDES_MODE("SLAVE"),
        .SRVAL_OQ(1'b0),
        .SRVAL_TQ(1'b0),
        .TBYTE_CTL("FALSE"),
        .TBYTE_SRC("FALSE"),
        .TRISTATE_WIDTH(1)
    ) u_oserdes_slave (
        .OFB(),
        .OQ(),
        .SHIFTOUT1(cascade_data_1),
        .SHIFTOUT2(cascade_data_2),
        .TBYTEOUT(),
        .TFB(),
        .TQ(),

        .CLK(tmds_clk_5x),
        .CLKDIV(pix_clk),
        .D1(1'b0),
        .D2(1'b0),
        .D3(tmds_word[8]),
        .D4(tmds_word[9]),
        .D5(1'b0),
        .D6(1'b0),
        .D7(1'b0),
        .D8(1'b0),
        .OCE(1'b1),
        .RST(serializer_reset),
        .SHIFTIN1(1'b0),
        .SHIFTIN2(1'b0),
        .T1(1'b0),
        .T2(1'b0),
        .T3(1'b0),
        .T4(1'b0),
        .TBYTEIN(1'b0),
        .TCE(1'b0)
    );

    OBUFDS u_tmds_output_buffer (
        .I(serial_data),
        .O(tmds_p),
        .OB(tmds_n)
    );

endmodule
