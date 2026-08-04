"""Build and run the portable cocotb core regression."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys

import cocotb_tools.config as cocotb_config
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner


COCOTB_ROOT = Path(__file__).resolve().parent
PROJECT_ROOT = COCOTB_ROOT.parents[1]
BUILD_ROOT = Path(os.getenv("COCOTB_BUILD_ROOT", "/tmp/fpga-video-stream-processor"))

CORE_SOURCES = [
    PROJECT_ROOT / "rtl/pkg/video_pkg.sv",
    PROJECT_ROOT / "rtl/core/frame_coord_tracker.sv",
    PROJECT_ROOT / "rtl/core/axis_elastic_buffer.sv",
    PROJECT_ROOT / "rtl/core/rgb_to_gray.sv",
    PROJECT_ROOT / "rtl/core/window_3x3.sv",
    PROJECT_ROOT / "rtl/core/stream_align_delay.sv",
    PROJECT_ROOT / "rtl/core/sobel_gx_gy.sv",
    PROJECT_ROOT / "rtl/core/sobel_magnitude.sv",
    PROJECT_ROOT / "rtl/core/video_mode_mux.sv",
    PROJECT_ROOT / "rtl/core/video_stream_core.sv",
]


def use_space_safe_cocotb_paths() -> None:
    """Alias cocotb build assets when the virtualenv path contains spaces."""

    if " " not in str(cocotb_config.share_dir) and " " not in str(cocotb_config.libs_dir):
        return

    runtime_root = BUILD_ROOT / "cocotb-runtime"
    runtime_root.mkdir(parents=True, exist_ok=True)
    for name, source in (
        ("share", cocotb_config.share_dir),
        ("libs", cocotb_config.libs_dir),
    ):
        alias = runtime_root / name
        if alias.is_symlink() or alias.exists():
            alias.unlink()
        alias.symlink_to(source, target_is_directory=True)

    cocotb_config.share_dir = runtime_root / "share"
    cocotb_config.libs_dir = runtime_root / "libs"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sim",
        choices=("verilator", "icarus"),
        default="verilator",
        help="HDL simulator backend",
    )
    parser.add_argument("--waves", action="store_true", help="record waveforms")
    parser.add_argument("--clean", action="store_true", help="rebuild from scratch")
    parser.add_argument(
        "--seed",
        type=lambda value: int(value, 0),
        default=0x5EED,
        help="deterministic cocotb seed",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    build_dir = BUILD_ROOT / f"cocotb-{args.sim}"
    use_space_safe_cocotb_paths()

    # These paths are inherited by the simulator process through the runner.
    sys.path.insert(0, str(PROJECT_ROOT))
    sys.path.insert(0, str(COCOTB_ROOT))

    runner = get_runner(args.sim)
    build_args = ["-Wall", "--assert"] if args.sim == "verilator" else []
    parameters = {"MAX_WIDTH": 64, "MAX_HEIGHT": 32}

    runner.build(
        sources=CORE_SOURCES,
        hdl_toplevel="video_stream_core",
        parameters=parameters,
        build_args=build_args,
        build_dir=build_dir,
        clean=args.clean,
        timescale=("1ns", "1ps"),
        waves=args.waves,
    )
    results_file = runner.test(
        test_module="tests.test_video_stream_core",
        hdl_toplevel="video_stream_core",
        hdl_toplevel_lang="verilog",
        parameters=parameters,
        build_dir=build_dir,
        test_dir=build_dir,
        seed=args.seed,
        extra_env={
            "VIDEO_COCOTB_SEED": hex(args.seed),
        },
        waves=args.waves,
    )

    test_count, failure_count = get_results(results_file)
    if failure_count:
        raise SystemExit(f"cocotb failed {failure_count} of {test_count} tests")


if __name__ == "__main__":
    main()
