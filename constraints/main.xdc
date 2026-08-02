# =============================================================================
# MicroPhase A7-Lite R1.1 board constraints
# Device: XC7A35T-FGG484-1
# Top:    top
#
# Sources:
#   - MicroPhase A7-LITE_R11 schematic
#   - Project RTL top-level port and clock-domain structure
#
# HDMI lane convention used by rtl/fpga/top.sv:
#   data[0] = blue, carrying {VSYNC, HSYNC} during blanking
#   data[1] = green
#   data[2] = red
# =============================================================================

create_clock -name clk_50m -period 20.000 [get_ports clk_50m]

# FPGA configuration bank voltage.
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]

# =============================================================================
# Primary system clock
# =============================================================================

# U10: 50 MHz single-ended oscillator, Bank 15 MRCC input.
set_property PACKAGE_PIN J19 [get_ports clk_50m]
set_property IOSTANDARD LVCMOS33 [get_ports clk_50m]


# =============================================================================
# User buttons
# =============================================================================
# K1 and K2 are active-low user buttons.
set_property PACKAGE_PIN AA1 [get_ports key_mode_n]
set_property PACKAGE_PIN W1  [get_ports key_threshold_up_n]

set_property IOSTANDARD LVCMOS33 \
    [get_ports {key_mode_n key_threshold_up_n}]

# All button inputs enter the pix_clk domain through the ASYNC_REG synchronizer
# in button_control. Do not time asynchronous board transitions against pix_clk.
set_false_path \
    -from [get_ports {key_mode_n key_threshold_up_n}]


# =============================================================================
# User LEDs
# =============================================================================

# D6/LED1 and D5/LED2 are active low on the A7-Lite board.
set_property PACKAGE_PIN M18 [get_ports led_frame_locked_n]
set_property PACKAGE_PIN N18 [get_ports led_fault_n]

set_property IOSTANDARD LVCMOS33 \
    [get_ports {led_frame_locked_n led_fault_n}]
set_property DRIVE 8 \
    [get_ports {led_frame_locked_n led_fault_n}]
set_property SLEW SLOW \
    [get_ports {led_frame_locked_n led_fault_n}]

# =============================================================================
# HDMI/DVI TMDS output
# =============================================================================

# Lane 0: blue channel and HSYNC/VSYNC control symbols.
set_property PACKAGE_PIN J20 [get_ports {hdmi_data_p[0]}]
set_property PACKAGE_PIN J21 [get_ports {hdmi_data_n[0]}]

# Lane 1: green channel.
set_property PACKAGE_PIN L19 [get_ports {hdmi_data_p[1]}]
set_property PACKAGE_PIN L20 [get_ports {hdmi_data_n[1]}]

# Lane 2: red channel.
set_property PACKAGE_PIN H20 [get_ports {hdmi_data_p[2]}]
set_property PACKAGE_PIN G20 [get_ports {hdmi_data_n[2]}]

# Forwarded pixel clock.
set_property PACKAGE_PIN K18 [get_ports hdmi_clk_p]
set_property PACKAGE_PIN K19 [get_ports hdmi_clk_n]

set_property IOSTANDARD TMDS_33 \
    [get_ports {
        hdmi_data_p[0] hdmi_data_n[0]
        hdmi_data_p[1] hdmi_data_n[1]
        hdmi_data_p[2] hdmi_data_n[2]
        hdmi_clk_p hdmi_clk_n
    }]
