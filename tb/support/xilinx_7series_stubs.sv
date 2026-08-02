// Black-box-compatible declarations used only by generic RTL lint.
// Functional serializer verification uses the Vivado UNISIM library.

module OSERDESE2 #(
    parameter string DATA_RATE_OQ = "DDR",
    parameter string DATA_RATE_TQ = "DDR",
    parameter integer DATA_WIDTH = 4,
    parameter logic INIT_OQ = 1'b0,
    parameter logic INIT_TQ = 1'b0,
    parameter string SERDES_MODE = "MASTER",
    parameter logic SRVAL_OQ = 1'b0,
    parameter logic SRVAL_TQ = 1'b0,
    parameter string TBYTE_CTL = "FALSE",
    parameter string TBYTE_SRC = "FALSE",
    parameter integer TRISTATE_WIDTH = 4
) (
    output logic OFB,
    output logic OQ,
    output logic SHIFTOUT1,
    output logic SHIFTOUT2,
    output logic TBYTEOUT,
    output logic TFB,
    output logic TQ,
    input logic CLK,
    input logic CLKDIV,
    input logic D1,
    input logic D2,
    input logic D3,
    input logic D4,
    input logic D5,
    input logic D6,
    input logic D7,
    input logic D8,
    input logic OCE,
    input logic RST,
    input logic SHIFTIN1,
    input logic SHIFTIN2,
    input logic T1,
    input logic T2,
    input logic T3,
    input logic T4,
    input logic TBYTEIN,
    input logic TCE
);

    assign OFB = 1'b0;
    assign OQ = 1'b0;
    assign SHIFTOUT1 = 1'b0;
    assign SHIFTOUT2 = 1'b0;
    assign TBYTEOUT = 1'b0;
    assign TFB = 1'b0;
    assign TQ = 1'b0;

endmodule

module OBUFDS (
    input logic I,
    output logic O,
    output logic OB
);

    assign O = I;
    assign OB = !I;

endmodule
