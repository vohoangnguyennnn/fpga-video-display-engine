"""Minimal AXI4-Stream Video source, sink, and reset helpers."""

from __future__ import annotations

from dataclasses import dataclass
import random
from typing import Callable, Iterable

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge, Timer
import numpy as np
from cocotb.clock import Clock


@dataclass(frozen=True, slots=True)
class AxiVideoBeat:
    """One RGB888 transfer with the v1.0 SOF and EOL markers."""

    data: int
    sof: bool
    eol: bool


def frame_to_beats(rgb_frame: np.ndarray) -> list[AxiVideoBeat]:
    """Flatten an RGB frame into raster-ordered AXI video transfers."""

    frame = np.asarray(rgb_frame, dtype=np.uint8)
    if frame.ndim != 3 or frame.shape[2] != 3:
        raise ValueError("rgb_frame must have shape (height, width, 3)")

    height, width, _ = frame.shape
    beats: list[AxiVideoBeat] = []
    for y in range(height):
        for x in range(width):
            red, green, blue = (int(channel) for channel in frame[y, x])
            beats.append(
                AxiVideoBeat(
                    data=(red << 16) | (green << 8) | blue,
                    sof=(x == 0 and y == 0),
                    eol=(x == width - 1),
                )
            )
    return beats


class AxiVideoSource:
    """Protocol-correct source that holds a beat until it is accepted."""

    def __init__(self, dut) -> None:
        self.dut = dut

    async def send_beats(
        self,
        beats: Iterable[AxiVideoBeat],
        *,
        gap_probability: float = 0.0,
        seed: int = 0,
        after_first_transfer: Callable[[], None] | None = None,
    ) -> int:
        transfers = list(beats)
        rng = random.Random(seed)
        index = 0
        cycle_count = 0
        holding_valid = False
        update_pending = False
        max_cycles = max(256, len(transfers) * 64)

        while index < len(transfers):
            await FallingEdge(self.dut.aclk)

            if update_pending:
                if after_first_transfer is not None:
                    after_first_transfer()
                update_pending = False

            if not holding_valid and rng.random() < gap_probability:
                self.dut.s_axis_tvalid.value = 0
                self.dut.s_axis_tuser.value = 0
                self.dut.s_axis_tlast.value = 0
            else:
                beat = transfers[index]
                self.dut.s_axis_tdata.value = beat.data
                self.dut.s_axis_tvalid.value = 1
                self.dut.s_axis_tuser.value = int(beat.sof)
                self.dut.s_axis_tlast.value = int(beat.eol)
                holding_valid = True

            await Timer(1, unit="ps")
            accepted = bool(
                int(self.dut.s_axis_tvalid.value)
                and int(self.dut.s_axis_tready.value)
            )

            if accepted:
                index += 1
                holding_valid = False
                if index == 1 and after_first_transfer is not None:
                    update_pending = True

            await RisingEdge(self.dut.aclk)
            cycle_count += 1
            assert cycle_count < max_cycles, "AXI source timed out waiting for ready"

        await FallingEdge(self.dut.aclk)
        self.dut.s_axis_tvalid.value = 0
        self.dut.s_axis_tuser.value = 0
        self.dut.s_axis_tlast.value = 0
        return index


class AxiVideoSink:
    """Handshake monitor with deterministic stalls and stability checking."""

    def __init__(self, dut) -> None:
        self.dut = dut

    async def receive_beats(
        self,
        count: int,
        *,
        ready_probability: float = 1.0,
        seed: int = 0,
    ) -> list[AxiVideoBeat]:
        rng = random.Random(seed)
        received: list[AxiVideoBeat] = []
        held_beat: AxiVideoBeat | None = None
        cycle_count = 0
        max_cycles = max(1024, count * 128)

        while len(received) < count:
            await FallingEdge(self.dut.aclk)
            ready = rng.random() < ready_probability
            self.dut.m_axis_tready.value = int(ready)
            await Timer(1, unit="ps")

            valid = bool(int(self.dut.m_axis_tvalid.value))
            current = None
            if valid:
                current = AxiVideoBeat(
                    data=int(self.dut.m_axis_tdata.value),
                    sof=bool(int(self.dut.m_axis_tuser.value)),
                    eol=bool(int(self.dut.m_axis_tlast.value)),
                )

            if held_beat is not None:
                assert valid, "output valid dropped while the sink was stalled"
                assert current == held_beat, "output payload changed while stalled"

            if valid and ready:
                assert current is not None
                received.append(current)
                held_beat = None
            elif valid:
                assert current is not None
                held_beat = current
            else:
                held_beat = None

            await RisingEdge(self.dut.aclk)
            cycle_count += 1
            assert cycle_count < max_cycles, "AXI sink timed out waiting for output"

        return received


def drive_config(dut, *, width: int, height: int, mode: int, threshold: int) -> None:
    """Drive the configuration values sampled with the next accepted SOF."""

    dut.cfg_frame_width.value = width
    dut.cfg_frame_height.value = height
    dut.cfg_mode.value = mode
    dut.cfg_threshold.value = threshold


async def reset_core(dut, cycles: int = 3) -> None:
    """Apply the synchronous active-low reset used by the reusable core."""

    dut.aresetn.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tuser.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 0
    drive_config(dut, width=3, height=3, mode=0, threshold=0)

    for _ in range(cycles):
        await RisingEdge(dut.aclk)

    await FallingEdge(dut.aclk)
    dut.aresetn.value = 1
    await RisingEdge(dut.aclk)
    await Timer(1, unit="ps")

    assert not int(dut.m_axis_tvalid.value), "output valid remained set after reset"
    assert not int(dut.status_in_frame.value), "frame status remained set after reset"
    assert not int(dut.status_protocol_error.value), "protocol error remained set after reset"


async def start_clock(dut) -> None:
    """Start the 100 MHz verification clock used for the vendor-neutral core."""

    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await Timer(1, unit="ns")
