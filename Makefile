PYTHON ?= python3
BUILD_ROOT ?= /tmp/fpga-video-stream-processor

PKG_SOURCE := rtl/pkg/video_pkg.sv

CORE_SOURCES := \
	rtl/pkg/video_pkg.sv \
	rtl/core/frame_coord_tracker.sv \
	rtl/core/axis_elastic_buffer.sv \
	rtl/core/rgb_to_gray.sv \
	rtl/core/window_3x3.sv \
	rtl/core/stream_align_delay.sv \
	rtl/core/sobel_gx_gy.sv \
	rtl/core/sobel_magnitude.sv \
	rtl/core/video_mode_mux.sv \
	rtl/core/video_stream_core.sv

FPGA_SOURCES := \
	rtl/fpga/reset_sync.sv \
	rtl/fpga/video_clock_reset.sv \
	rtl/fpga/video_timing_720p.sv \
	rtl/fpga/video_test_pattern.sv \
	rtl/fpga/button_control.sv \
	rtl/fpga/axis_to_raster.sv \
	rtl/fpga/tmds_encoder.sv \
	rtl/fpga/tmds_serializer.sv \
	rtl/fpga/top.sv

SUPPORT_SOURCES := \
	tb/support/xilinx_7series_stubs.sv \
	tb/support/video_clk_wiz.sv

VERILATOR_TEST_FLAGS := \
	--binary --timing --timescale 1ns/1ps \
	--sv --assert -Wall

VERILATOR_TOP_FLAGS := \
	-Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
	-Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM

UNIT_TARGETS := \
	test-axis-elastic-buffer \
	test-frame-coord-tracker \
	test-rgb-to-gray \
	test-window-3x3 \
	test-sobel-gx-gy \
	test-sobel-magnitude \
	test-stream-align-delay \
	test-video-mode-mux \
	test-reset-sync \
	test-video-clock-reset \
	test-video-timing-720p \
	test-video-test-pattern \
	test-axis-to-raster \
	test-button-control \
	test-tmds-encoder

INTEGRATION_TARGETS := \
	test-video-stream-core \
	test-top

.PHONY: help ci lint test test-all test-rtl test-unit test-integration \
	test-model test-cocotb test-xsim vivado \
	$(UNIT_TARGETS) $(INTEGRATION_TARGETS) \
	test-tmds-serializer clean

help:
	@echo "Available targets:"
	@echo "  make ci                Run the checks used by GitHub Actions"
	@echo "  make lint              Lint the complete RTL hierarchy"
	@echo "  make test-unit         Run portable SystemVerilog unit tests"
	@echo "  make test-integration  Run core and board integration tests"
	@echo "  make test-rtl          Run lint plus all portable RTL tests"
	@echo "  make test-model        Run the Python reference-model tests"
	@echo "  make test-cocotb       Run the core cocotb smoke tests"
	@echo "  make test-xsim         Run the Xilinx UNISIM serializer test"
	@echo "  make test              Run portable RTL and model tests"
	@echo "  make test-all          Run portable tests plus Xsim"
	@echo "  make vivado            Build the FPGA bitstream locally with Vivado"
	@echo "  make clean             Remove simulator build products"

ci: test-rtl test-model test-cocotb

lint:
	verilator --lint-only --sv --timing --timescale 1ns/1ps -Wall \
		$(VERILATOR_TOP_FLAGS) \
		--top-module top \
		$(CORE_SOURCES) $(FPGA_SOURCES) $(SUPPORT_SOURCES)

test: test-rtl test-model

test-all: test test-xsim

test-rtl: lint test-unit test-integration

test-unit: $(UNIT_TARGETS)

test-integration: $(INTEGRATION_TARGETS)

test-model:
	$(PYTHON) -m unittest discover -s tb/model -p 'test_*.py'

test-cocotb:
	$(PYTHON) tb/cocotb/run.py --sim verilator

test-xsim: test-tmds-serializer

vivado:
	@command -v vivado >/dev/null 2>&1 || \
		(echo "Vivado is not on PATH; source the Vivado environment first" && false)
	mkdir -p build/vivado
	vivado -mode batch \
		-source fpga/vivado/build.tcl \
		-log build/vivado/vivado.log \
		-journal build/vivado/vivado.jou

define run_sv_test
	mkdir -p $(BUILD_ROOT)/$(1)
	CCACHE_DISABLE=1 verilator $(VERILATOR_TEST_FLAGS) \
		--top-module $(1)_tb \
		--Mdir $(BUILD_ROOT)/$(1) \
		-o $(1)_tb \
		$(2)
	$(BUILD_ROOT)/$(1)/$(1)_tb
endef

test-axis-elastic-buffer:
	$(call run_sv_test,axis_elastic_buffer,$(PKG_SOURCE) rtl/core/axis_elastic_buffer.sv tb/unit/axis_elastic_buffer_tb.sv)

test-frame-coord-tracker:
	$(call run_sv_test,frame_coord_tracker,$(PKG_SOURCE) rtl/core/frame_coord_tracker.sv tb/unit/frame_coord_tracker_tb.sv)

test-rgb-to-gray:
	$(call run_sv_test,rgb_to_gray,$(PKG_SOURCE) rtl/core/rgb_to_gray.sv tb/unit/rgb_to_gray_tb.sv)

test-window-3x3:
	$(call run_sv_test,window_3x3,$(PKG_SOURCE) rtl/core/window_3x3.sv tb/unit/window_3x3_tb.sv)

test-sobel-gx-gy:
	$(call run_sv_test,sobel_gx_gy,rtl/core/sobel_gx_gy.sv tb/unit/sobel_gx_gy_tb.sv)

test-sobel-magnitude:
	$(call run_sv_test,sobel_magnitude,rtl/core/sobel_magnitude.sv tb/unit/sobel_magnitude_tb.sv)

test-stream-align-delay:
	$(call run_sv_test,stream_align_delay,$(PKG_SOURCE) rtl/core/stream_align_delay.sv tb/unit/stream_align_delay_tb.sv)

test-video-mode-mux:
	$(call run_sv_test,video_mode_mux,$(PKG_SOURCE) rtl/core/video_mode_mux.sv tb/unit/video_mode_mux_tb.sv)

test-reset-sync:
	$(call run_sv_test,reset_sync,rtl/fpga/reset_sync.sv tb/unit/reset_sync_tb.sv)

test-video-clock-reset:
	$(call run_sv_test,video_clock_reset,rtl/fpga/reset_sync.sv rtl/fpga/video_clock_reset.sv tb/support/video_clk_wiz.sv tb/unit/video_clock_reset_tb.sv)

test-video-timing-720p:
	$(call run_sv_test,video_timing_720p,rtl/fpga/video_timing_720p.sv tb/unit/video_timing_720p_tb.sv)

test-video-test-pattern:
	$(call run_sv_test,video_test_pattern,rtl/fpga/video_test_pattern.sv tb/unit/video_test_pattern_tb.sv)

test-axis-to-raster:
	$(call run_sv_test,axis_to_raster,rtl/fpga/axis_to_raster.sv tb/unit/axis_to_raster_tb.sv)

test-button-control:
	$(call run_sv_test,button_control,rtl/fpga/button_control.sv tb/unit/button_control_tb.sv)

test-tmds-encoder:
	$(call run_sv_test,tmds_encoder,rtl/fpga/tmds_encoder.sv tb/unit/tmds_encoder_tb.sv)

test-video-stream-core:
	$(call run_sv_test,video_stream_core,$(CORE_SOURCES) tb/integration/video_stream_core/video_stream_core_tb.sv)

test-top:
	mkdir -p $(BUILD_ROOT)/top
	CCACHE_DISABLE=1 verilator $(VERILATOR_TEST_FLAGS) \
		$(VERILATOR_TOP_FLAGS) \
		--top-module top_tb \
		--Mdir $(BUILD_ROOT)/top \
		-o top_tb \
		$(CORE_SOURCES) $(FPGA_SOURCES) $(SUPPORT_SOURCES) \
		tb/integration/top/top_tb.sv
	$(BUILD_ROOT)/top/top_tb

test-tmds-serializer:
	test -n "$(XILINX_VIVADO)" || \
		(echo "XILINX_VIVADO is not set; source the Vivado environment first" && false)
	mkdir -p $(BUILD_ROOT)/tmds_serializer_xsim
	cd "$(BUILD_ROOT)/tmds_serializer_xsim" && \
		xvlog --sv --nolog \
		"$(CURDIR)/rtl/fpga/tmds_serializer.sv" \
		"$(CURDIR)/tb/unit/tmds_serializer_tb.sv" \
		"$(XILINX_VIVADO)/data/verilog/src/glbl.v"
	cd "$(BUILD_ROOT)/tmds_serializer_xsim" && \
		xelab --standalone --timescale 1ns/1ps \
		-L unisims_ver -L secureip \
		work.tmds_serializer_tb work.glbl \
		-s tmds_serializer_tb_standalone --nolog
	cd "$(BUILD_ROOT)/tmds_serializer_xsim" && ./axsim.sh

clean:
	$(RM) -r $(BUILD_ROOT)
