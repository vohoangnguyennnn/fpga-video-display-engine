// Single ownership point for the 50 MHz board oscillator input.
//
// Both Clocking Wizard instances are configured with Input Source = No buffer.
// They consume clk_50m_global, so only this module owns the physical input
// buffer and global distribution buffer for package pin J19.

module board_clock_buffer (
    input  logic clk_50m_pad,
    output logic clk_50m_global
);

    logic clk_50m_ibuf;

    IBUF u_clk_50m_ibuf (
        .I(clk_50m_pad),
        .O(clk_50m_ibuf)
    );

    BUFG u_clk_50m_bufg (
        .I(clk_50m_ibuf),
        .O(clk_50m_global)
    );

endmodule
