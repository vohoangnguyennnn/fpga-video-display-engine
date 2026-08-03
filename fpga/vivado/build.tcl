# Reproducible local Vivado build for the MicroPhase A7-Lite 35T.
# Run from any directory with:
#   vivado -mode batch -source fpga/vivado/build.tcl

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../..]]
set build_dir [file join $project_root build vivado]
set project_dir [file join $build_dir project]
set report_dir [file join $build_dir reports]

set project_name fpga_video_stream_processor
set target_part xc7a35tfgg484-1
set top_module top

file mkdir $build_dir
file mkdir $report_dir

set rtl_sources [list \
    [file join $project_root rtl/pkg/video_pkg.sv] \
    [file join $project_root rtl/core/frame_coord_tracker.sv] \
    [file join $project_root rtl/core/axis_elastic_buffer.sv] \
    [file join $project_root rtl/core/rgb_to_gray.sv] \
    [file join $project_root rtl/core/window_3x3.sv] \
    [file join $project_root rtl/core/stream_align_delay.sv] \
    [file join $project_root rtl/core/sobel_gx_gy.sv] \
    [file join $project_root rtl/core/sobel_magnitude.sv] \
    [file join $project_root rtl/core/video_mode_mux.sv] \
    [file join $project_root rtl/core/video_stream_core.sv] \
    [file join $project_root rtl/fpga/reset_sync.sv] \
    [file join $project_root rtl/fpga/video_clock_reset.sv] \
    [file join $project_root rtl/fpga/video_timing_720p.sv] \
    [file join $project_root rtl/fpga/video_test_pattern.sv] \
    [file join $project_root rtl/fpga/button_control.sv] \
    [file join $project_root rtl/fpga/axis_to_raster.sv] \
    [file join $project_root rtl/fpga/tmds_encoder.sv] \
    [file join $project_root rtl/fpga/tmds_serializer.sv] \
    [file join $project_root rtl/fpga/top.sv] \
]

set constraints_file [file join $project_root constraints/main.xdc]
set clock_ip_file [file join $project_root ip/video_clk_wiz/video_clk_wiz.xci]

foreach source_file [concat $rtl_sources [list $constraints_file $clock_ip_file]] {
    if {![file exists $source_file]} {
        error "Required build input does not exist: $source_file"
    }
}

create_project -force $project_name $project_dir -part $target_part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -norecurse $rtl_sources
add_files -fileset constrs_1 -norecurse [list $constraints_file]

# Import a managed copy so generated IP products stay under build/vivado.
import_ip -files [list $clock_ip_file] -name video_clk_wiz
upgrade_ip [get_ips video_clk_wiz]
generate_target all [get_ips video_clk_wiz]

set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

puts "VIVADO_BUILD: starting synthesis"
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {
    error "Synthesis did not complete: [get_property STATUS [get_runs synth_1]]"
}

puts "VIVADO_BUILD: starting implementation and bitstream generation"
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {
    error "Implementation did not complete: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir timing_summary.rpt]
report_utilization -hierarchical \
    -file [file join $report_dir utilization.rpt]
report_drc -file [file join $report_dir drc.rpt]

set bitstreams [glob -nocomplain \
    [file join $project_dir ${project_name}.runs impl_1 *.bit]]
if {[llength $bitstreams] != 1} {
    error "Expected one generated bitstream, found [llength $bitstreams]"
}
file copy -force [lindex $bitstreams 0] \
    [file join $build_dir ${project_name}.bit]

puts "VIVADO_BUILD: PASS"
puts "Bitstream: [file join $build_dir ${project_name}.bit]"
puts "Reports:   $report_dir"
close_project
