"""End-to-end cocotb checks for the reusable video stream core."""

from __future__ import annotations

import os

import cocotb
import numpy as np
from cocotb.triggers import RisingEdge, Timer

from common.axi_video import (
    AxiVideoBeat,
    AxiVideoSink,
    AxiVideoSource,
    drive_config,
    frame_to_beats,
    reset_core,
    start_clock,
)
from common.scoreboard import check_frame
from models.video_model import FrameConfig, VideoMode, process_frame


BASE_SEED = int(os.getenv("VIDEO_COCOTB_SEED", "0x5eed"), 0)


async def run_checked_frame(
    dut,
    rgb_frame: np.ndarray,
    config: FrameConfig,
    *,
    source_gap_probability: float = 0.0,
    sink_ready_probability: float = 1.0,
    seed: int = BASE_SEED,
    after_first_transfer=None,
    prior_protocol_error: bool = False,
    label: str,
) -> None:
    drive_config(
        dut,
        width=config.frame_width,
        height=config.frame_height,
        mode=int(config.mode),
        threshold=config.threshold,
    )

    expected = process_frame(
        rgb_frame,
        config,
        prior_protocol_error=prior_protocol_error,
    )
    beats = frame_to_beats(rgb_frame)
    source = AxiVideoSource(dut)
    sink = AxiVideoSink(dut)

    source_task = cocotb.start_soon(
        source.send_beats(
            beats,
            gap_probability=source_gap_probability,
            seed=seed,
            after_first_transfer=after_first_transfer,
        )
    )
    actual = await sink.receive_beats(
        len(beats),
        ready_probability=sink_ready_probability,
        seed=seed ^ 0xA5A5,
    )
    accepted_count = await source_task
    await Timer(1, unit="ps")

    assert accepted_count == len(beats), f"{label}: input transfer count mismatch"
    check_frame(actual, expected, label=label)
    assert bool(int(dut.status_protocol_error.value)) == expected.status_protocol_error


def vertical_step(height: int, width: int) -> np.ndarray:
    frame = np.zeros((height, width, 3), dtype=np.uint8)
    frame[:, width // 2 :, :] = 255
    return frame


@cocotb.test()
async def test_all_modes_with_backpressure(dut) -> None:
    """Check all v1.0 modes, markers, borders, gaps, and output stalls."""

    dut._log.info("VIDEO_COCOTB_SEED=0x%x", BASE_SEED)
    await start_clock(dut)
    await reset_core(dut)

    rng = np.random.default_rng(BASE_SEED)
    cases = [
        (
            rng.integers(0, 256, size=(1, 1, 3), dtype=np.uint8),
            FrameConfig(1, 1, VideoMode.PASSTHROUGH, 0),
            0.0,
            1.0,
            "1x1 passthrough",
        ),
        (
            rng.integers(0, 256, size=(3, 4, 3), dtype=np.uint8),
            FrameConfig(4, 3, VideoMode.GRAYSCALE, 0),
            0.20,
            0.75,
            "grayscale",
        ),
        (
            vertical_step(5, 5),
            FrameConfig(5, 5, VideoMode.SOBEL_MAGNITUDE, 0),
            0.25,
            0.65,
            "Sobel magnitude",
        ),
        (
            vertical_step(5, 5),
            FrameConfig(5, 5, VideoMode.BINARY_EDGE, 169),
            0.15,
            0.70,
            "binary edge",
        ),
    ]

    for index, (frame, config, gap_probability, ready_probability, label) in enumerate(cases):
        await run_checked_frame(
            dut,
            frame,
            config,
            source_gap_probability=gap_probability,
            sink_ready_probability=ready_probability,
            seed=BASE_SEED + index,
            label=label,
        )

    assert not int(dut.status_in_frame.value), "frame status remained set after drain"


@cocotb.test()
async def test_configuration_is_committed_at_sof(dut) -> None:
    """Changing raw configuration after SOF must not alter the active frame."""

    await start_clock(dut)
    await reset_core(dut)

    rng = np.random.default_rng(BASE_SEED ^ 0x1234)
    frame = rng.integers(0, 256, size=(4, 4, 3), dtype=np.uint8)
    config = FrameConfig(4, 4, VideoMode.PASSTHROUGH, 0)

    def change_pending_configuration() -> None:
        drive_config(dut, width=5, height=5, mode=int(VideoMode.BINARY_EDGE), threshold=255)

    await run_checked_frame(
        dut,
        frame,
        config,
        source_gap_probability=0.20,
        sink_ready_probability=0.60,
        seed=BASE_SEED ^ 0x2222,
        after_first_transfer=change_pending_configuration,
        label="frame-atomic configuration",
    )


@cocotb.test()
async def test_protocol_error_is_sticky_and_next_frame_recovers(dut) -> None:
    """A missing SOF is reported without contaminating the next legal frame."""

    await start_clock(dut)
    await reset_core(dut)
    drive_config(dut, width=3, height=3, mode=int(VideoMode.PASSTHROUGH), threshold=0)
    dut.m_axis_tready.value = 1

    source = AxiVideoSource(dut)
    accepted = await source.send_beats(
        [AxiVideoBeat(data=0x123456, sof=False, eol=False)],
        seed=BASE_SEED,
    )
    assert accepted == 1, "malformed transfer was not accepted"

    for _ in range(4):
        await RisingEdge(dut.aclk)
    await Timer(1, unit="ps")
    assert int(dut.status_protocol_error.value), "missing SOF was not reported"
    assert not int(dut.m_axis_tvalid.value), "malformed input produced an output transfer"

    frame = np.arange(27, dtype=np.uint8).reshape(3, 3, 3)
    config = FrameConfig(3, 3, VideoMode.PASSTHROUGH, 0)
    await run_checked_frame(
        dut,
        frame,
        config,
        source_gap_probability=0.10,
        sink_ready_probability=0.70,
        seed=BASE_SEED ^ 0x3333,
        prior_protocol_error=True,
        label="post-error recovery",
    )

