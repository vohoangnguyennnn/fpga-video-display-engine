"""Transaction-level reference model for the fixed DDR3 framebuffer.

This module is deliberately independent of simulator timing.  It models the
contracts that must remain true across the RTL implementation:

* the fixed XRGB8888 memory layout and framebuffer address map;
* 128-bit AXI beat packing and 4-KiB-safe burst planning;
* sparse byte-addressable memory behavior for scoreboards; and
* two-slot ownership, response-qualified writes, and vblank-only promotion.

It is not a MIG timing model and does not duplicate AXI ready/valid state
machines.  Protocol timing remains the responsibility of the SystemVerilog
and cocotb environments; this model supplies their specification-level oracle.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum, IntEnum
from numbers import Integral
from typing import Iterable


FRAME_WIDTH = 1_280
FRAME_HEIGHT = 720
BYTES_PER_PIXEL = 4
STRIDE_BYTES = 0x0000_1400
FB0_BASE_ADDR = 0x0000_0000
FB1_BASE_ADDR = 0x0040_0000
FB_SLOT_BYTES = 0x0040_0000
FRAMEBUFFER_COUNT = 2
AXI_ADDR_WIDTH = 29
AXI_DATA_BYTES = 16
DMA_BURST_BEATS = 16
AXI_BOUNDARY_BYTES = 4_096


def _integer(name: str, value: object, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, Integral):
        raise TypeError(f"{name} must be an integer")
    integer_value = int(value)
    if not minimum <= integer_value <= maximum:
        raise ValueError(f"{name} must be in the range {minimum}..{maximum}")
    return integer_value


def _power_of_two(value: int) -> bool:
    return value > 0 and (value & (value - 1)) == 0


@dataclass(frozen=True, slots=True)
class AxiBurst:
    """One aligned incrementing AXI burst from the reference planner."""

    address: int
    beats: int
    beat_bytes: int = AXI_DATA_BYTES
    boundary_bytes: int = AXI_BOUNDARY_BYTES

    def __post_init__(self) -> None:
        address = _integer("address", self.address, 0, (1 << 64) - 1)
        beats = _integer("beats", self.beats, 1, 256)
        beat_bytes = _integer("beat_bytes", self.beat_bytes, 1, 4_096)
        boundary_bytes = _integer(
            "boundary_bytes", self.boundary_bytes, beat_bytes, 1 << 30
        )

        if not _power_of_two(beat_bytes):
            raise ValueError("beat_bytes must be a power of two")
        if not _power_of_two(boundary_bytes):
            raise ValueError("boundary_bytes must be a power of two")
        if boundary_bytes % beat_bytes:
            raise ValueError("boundary_bytes must be a multiple of beat_bytes")
        if address % beat_bytes:
            raise ValueError("AXI burst address must be beat aligned")
        if (address % boundary_bytes) + (beats * beat_bytes) > boundary_bytes:
            raise ValueError("AXI burst crosses its boundary")

        object.__setattr__(self, "address", address)
        object.__setattr__(self, "beats", beats)
        object.__setattr__(self, "beat_bytes", beat_bytes)
        object.__setattr__(self, "boundary_bytes", boundary_bytes)

    @property
    def axlen(self) -> int:
        """AXI encoded burst length."""

        return self.beats - 1

    @property
    def byte_count(self) -> int:
        return self.beats * self.beat_bytes

    @property
    def end_address(self) -> int:
        """Exclusive end address."""

        return self.address + self.byte_count


def plan_axi_bursts(
    base_address: object,
    total_beats: object,
    *,
    max_burst_beats: object = DMA_BURST_BEATS,
    beat_bytes: object = AXI_DATA_BYTES,
    boundary_bytes: object = AXI_BOUNDARY_BYTES,
) -> tuple[AxiBurst, ...]:
    """Plan aligned INCR bursts without crossing a 4-KiB boundary."""

    address = _integer("base_address", base_address, 0, (1 << 64) - 1)
    remaining = _integer("total_beats", total_beats, 0, (1 << 63) - 1)
    maximum_beats = _integer("max_burst_beats", max_burst_beats, 1, 256)
    bytes_per_beat = _integer("beat_bytes", beat_bytes, 1, 4_096)
    boundary = _integer(
        "boundary_bytes", boundary_bytes, bytes_per_beat, 1 << 30
    )

    if not _power_of_two(bytes_per_beat):
        raise ValueError("beat_bytes must be a power of two")
    if not _power_of_two(boundary) or boundary % bytes_per_beat:
        raise ValueError(
            "boundary_bytes must be a power-of-two multiple of beat_bytes"
        )
    if address % bytes_per_beat:
        raise ValueError("base_address must be beat aligned")

    bursts: list[AxiBurst] = []
    while remaining:
        offset = address % boundary
        beats_to_boundary = (boundary - offset) // bytes_per_beat
        burst_beats = min(remaining, maximum_beats, beats_to_boundary)
        if burst_beats <= 0:
            raise AssertionError("burst planner made no forward progress")

        burst = AxiBurst(
            address=address,
            beats=burst_beats,
            beat_bytes=bytes_per_beat,
            boundary_bytes=boundary,
        )
        bursts.append(burst)
        address = burst.end_address
        remaining -= burst_beats

    return tuple(bursts)


@dataclass(frozen=True, slots=True)
class FramebufferLayout:
    """Fixed-function geometry shared by the framebuffer RTL and model."""

    width: int = FRAME_WIDTH
    height: int = FRAME_HEIGHT
    bytes_per_pixel: int = BYTES_PER_PIXEL
    stride_bytes: int = STRIDE_BYTES
    base_addresses: tuple[int, int] = (FB0_BASE_ADDR, FB1_BASE_ADDR)
    slot_bytes: int = FB_SLOT_BYTES
    axi_addr_width: int = AXI_ADDR_WIDTH
    axi_data_bytes: int = AXI_DATA_BYTES
    burst_beats: int = DMA_BURST_BEATS
    boundary_bytes: int = AXI_BOUNDARY_BYTES

    def __post_init__(self) -> None:
        width = _integer("width", self.width, 1, (1 << 31) - 1)
        height = _integer("height", self.height, 1, (1 << 31) - 1)
        bytes_per_pixel = _integer(
            "bytes_per_pixel", self.bytes_per_pixel, 1, 64
        )
        stride_bytes = _integer(
            "stride_bytes", self.stride_bytes, 1, (1 << 63) - 1
        )
        slot_bytes = _integer("slot_bytes", self.slot_bytes, 1, (1 << 63) - 1)
        axi_addr_width = _integer("axi_addr_width", self.axi_addr_width, 1, 63)
        axi_data_bytes = _integer(
            "axi_data_bytes", self.axi_data_bytes, 1, 4_096
        )
        burst_beats = _integer("burst_beats", self.burst_beats, 1, 256)
        boundary_bytes = _integer(
            "boundary_bytes", self.boundary_bytes, axi_data_bytes, 1 << 30
        )

        if bytes_per_pixel != 4:
            raise ValueError("the release framebuffer format is XRGB8888")
        if axi_data_bytes != 16:
            raise ValueError("the release AXI data width is fixed at 128 bits")
        if stride_bytes != width * bytes_per_pixel:
            raise ValueError("stride_bytes must equal the active line size")
        if width % (axi_data_bytes // bytes_per_pixel):
            raise ValueError("each active line must contain complete AXI beats")
        if not _power_of_two(boundary_bytes):
            raise ValueError("boundary_bytes must be a power of two")
        if boundary_bytes % axi_data_bytes:
            raise ValueError("boundary_bytes must be a multiple of an AXI beat")
        if (burst_beats * axi_data_bytes) > boundary_bytes:
            raise ValueError("maximum burst cannot exceed one AXI boundary")
        if slot_bytes % boundary_bytes:
            raise ValueError("slot_bytes must be boundary aligned")

        if not isinstance(self.base_addresses, tuple) or len(self.base_addresses) != 2:
            raise TypeError("base_addresses must be a two-element tuple")
        bases = tuple(
            _integer(f"base_addresses[{index}]", value, 0, (1 << 63) - 1)
            for index, value in enumerate(self.base_addresses)
        )
        if any(base % boundary_bytes for base in bases):
            raise ValueError("framebuffer bases must be boundary aligned")
        if bases[0] + slot_bytes > bases[1]:
            raise ValueError("framebuffer slots overlap")

        frame_bytes = height * stride_bytes
        if frame_bytes > slot_bytes:
            raise ValueError("active frame does not fit in its slot")
        aperture_bytes = 1 << axi_addr_width
        if bases[-1] + slot_bytes > aperture_bytes:
            raise ValueError("framebuffer slots exceed the MIG aperture")

        object.__setattr__(self, "width", width)
        object.__setattr__(self, "height", height)
        object.__setattr__(self, "bytes_per_pixel", bytes_per_pixel)
        object.__setattr__(self, "stride_bytes", stride_bytes)
        object.__setattr__(self, "base_addresses", bases)
        object.__setattr__(self, "slot_bytes", slot_bytes)
        object.__setattr__(self, "axi_addr_width", axi_addr_width)
        object.__setattr__(self, "axi_data_bytes", axi_data_bytes)
        object.__setattr__(self, "burst_beats", burst_beats)
        object.__setattr__(self, "boundary_bytes", boundary_bytes)

    @property
    def frame_pixels(self) -> int:
        return self.width * self.height

    @property
    def active_frame_bytes(self) -> int:
        return self.height * self.stride_bytes

    @property
    def pixels_per_axi_beat(self) -> int:
        return self.axi_data_bytes // self.bytes_per_pixel

    @property
    def frame_beats(self) -> int:
        return self.active_frame_bytes // self.axi_data_bytes

    @property
    def mig_aperture_bytes(self) -> int:
        return 1 << self.axi_addr_width

    @property
    def framebuffer_aperture_bytes(self) -> int:
        return self.base_addresses[-1] + self.slot_bytes - self.base_addresses[0]

    def base_address(self, buffer_index: object) -> int:
        index = _integer("buffer_index", buffer_index, 0, FRAMEBUFFER_COUNT - 1)
        return self.base_addresses[index]

    def pixel_address(self, buffer_index: object, x: object, y: object) -> int:
        column = _integer("x", x, 0, self.width - 1)
        row = _integer("y", y, 0, self.height - 1)
        return (
            self.base_address(buffer_index)
            + (row * self.stride_bytes)
            + (column * self.bytes_per_pixel)
        )

    def frame_bursts(self, buffer_index: object) -> tuple[AxiBurst, ...]:
        return plan_axi_bursts(
            self.base_address(buffer_index),
            self.frame_beats,
            max_burst_beats=self.burst_beats,
            beat_bytes=self.axi_data_bytes,
            boundary_bytes=self.boundary_bytes,
        )


def pack_xrgb8888(rgb888: object) -> int:
    """Pack one RGB888 stream pixel into the 32-bit framebuffer format."""

    return _integer("rgb888", rgb888, 0, 0xFF_FFFF)


def unpack_xrgb8888(xrgb8888: object) -> int:
    """Discard X and return the RGB888 payload used by the RTL."""

    word = _integer("xrgb8888", xrgb8888, 0, 0xFFFF_FFFF)
    return word & 0xFF_FFFF


def pack_axi_beat(rgb_pixels: Iterable[object]) -> int:
    """Pack four consecutive RGB888 pixels into one 128-bit AXI beat.

    The first stream pixel occupies bits ``31:0``.  This matches the RTL's
    lane ordering and makes increasing pixel addresses map to increasing AXI
    byte lanes on the little-endian memory interface.
    """

    pixels = tuple(rgb_pixels)
    if len(pixels) != AXI_DATA_BYTES // BYTES_PER_PIXEL:
        raise ValueError("one AXI beat requires exactly four RGB pixels")

    beat = 0
    for lane, pixel in enumerate(pixels):
        beat |= pack_xrgb8888(pixel) << (lane * 32)
    return beat


def unpack_axi_beat(axi_data: object) -> tuple[int, int, int, int]:
    """Unpack one 128-bit beat into four RGB888 stream pixels."""

    beat = _integer("axi_data", axi_data, 0, (1 << 128) - 1)
    return tuple(
        unpack_xrgb8888((beat >> (lane * 32)) & 0xFFFF_FFFF)
        for lane in range(AXI_DATA_BYTES // BYTES_PER_PIXEL)
    )


@dataclass(slots=True)
class FramebufferMemoryModel:
    """Sparse byte-addressable memory oracle for DMA scoreboards."""

    layout: FramebufferLayout = field(default_factory=FramebufferLayout)
    _beats: dict[int, int] = field(default_factory=dict, init=False, repr=False)

    def _beat_address(self, address: object) -> int:
        beat_address = _integer(
            "address", address, 0, self.layout.mig_aperture_bytes - 1
        )
        if beat_address % self.layout.axi_data_bytes:
            raise ValueError("memory access must be AXI-beat aligned")
        if beat_address + self.layout.axi_data_bytes > self.layout.mig_aperture_bytes:
            raise ValueError("memory access exceeds the MIG aperture")
        return beat_address

    def write_beat(
        self,
        address: object,
        data: object,
        strobe: object = (1 << AXI_DATA_BYTES) - 1,
    ) -> None:
        """Apply one AXI write beat, including byte strobes."""

        beat_address = self._beat_address(address)
        beat_data = _integer("data", data, 0, (1 << 128) - 1)
        write_strobe = _integer(
            "strobe", strobe, 0, (1 << self.layout.axi_data_bytes) - 1
        )
        current = self._beats.get(beat_address, 0)
        updated = current
        for byte_lane in range(self.layout.axi_data_bytes):
            if (write_strobe >> byte_lane) & 1:
                shift = byte_lane * 8
                updated &= ~(0xFF << shift)
                updated |= ((beat_data >> shift) & 0xFF) << shift
        self._beats[beat_address] = updated

    def read_beat(self, address: object) -> int:
        """Return one beat; unwritten memory reads as zero in this oracle."""

        return self._beats.get(self._beat_address(address), 0)

    def write_frame(self, buffer_index: object, rgb_pixels: Iterable[object]) -> None:
        """Store one complete raster-order RGB frame in the selected slot."""

        pixels = tuple(rgb_pixels)
        if len(pixels) != self.layout.frame_pixels:
            raise ValueError(
                f"frame requires {self.layout.frame_pixels} pixels, "
                f"received {len(pixels)}"
            )

        pixels_per_beat = self.layout.pixels_per_axi_beat
        base = self.layout.base_address(buffer_index)
        for beat_index in range(self.layout.frame_beats):
            first_pixel = beat_index * pixels_per_beat
            beat_pixels = pixels[first_pixel : first_pixel + pixels_per_beat]
            self.write_beat(
                base + (beat_index * self.layout.axi_data_bytes),
                pack_axi_beat(beat_pixels),
            )

    def read_frame(self, buffer_index: object) -> tuple[int, ...]:
        """Return one complete slot as raster-order RGB888 pixels."""

        base = self.layout.base_address(buffer_index)
        pixels: list[int] = []
        for beat_index in range(self.layout.frame_beats):
            beat = self.read_beat(
                base + (beat_index * self.layout.axi_data_bytes)
            )
            pixels.extend(unpack_axi_beat(beat))
        return tuple(pixels)

    def clear(self) -> None:
        self._beats.clear()


class SlotState(IntEnum):
    """Externally visible framebuffer ownership encoding."""

    FREE = 0
    WRITING = 1
    READY = 2
    READING = 3


class VBlankAction(Enum):
    """Transaction-level result of servicing one vertical blank."""

    BLACK = "black"
    SWAP = "swap"
    REPEAT = "repeat"
    DEADLINE_MISS = "deadline_miss"


@dataclass(slots=True)
class DoubleBufferModel:
    """Reference policy model for the two-slot ownership controller.

    Commands are explicit: a pending command must be accepted before its DMA
    can complete.  This keeps completion ordering and response-qualified
    promotion visible without attempting to model UI-clock latency.
    """

    slot_states: list[SlotState] = field(init=False)
    front_buffer: int = field(init=False)
    back_buffer: int = field(init=False)
    display_valid: bool = field(init=False)
    pending_write: int | None = field(init=False)
    pending_read: int | None = field(init=False)
    active_write: int | None = field(init=False)
    active_read: int | None = field(init=False)
    read_released: bool = field(init=False)
    status_write_error: bool = field(init=False)
    status_read_error: bool = field(init=False)
    status_read_deadline_miss: bool = field(init=False)
    swap_count: int = field(init=False)
    repeat_count: int = field(init=False)

    def __post_init__(self) -> None:
        self.reset()

    @property
    def front_state(self) -> SlotState:
        return self.slot_states[self.front_buffer]

    @property
    def back_state(self) -> SlotState:
        return self.slot_states[self.back_buffer]

    def reset(self) -> None:
        self.slot_states = [SlotState.FREE, SlotState.FREE]
        # Before first promotion, FB0 is the selected back slot and FB1 is the
        # distinct invalid front slot, matching the RTL reset state.
        self.front_buffer = 1
        self.back_buffer = 0
        self.display_valid = False
        self.pending_write = 0
        self.pending_read = None
        self.active_write = None
        self.active_read = None
        self.read_released = True
        self.status_write_error = False
        self.status_read_error = False
        self.status_read_deadline_miss = False
        self.swap_count = 0
        self.repeat_count = 0
        self.assert_invariants()

    def accept_write(self) -> int:
        if self.pending_write is None:
            raise RuntimeError("no write command is pending")
        if self.active_write is not None:
            raise RuntimeError("a write is already active")

        index = self.pending_write
        if index != self.back_buffer:
            raise RuntimeError("write command does not target the back buffer")
        if self.slot_states[index] is not SlotState.FREE:
            raise RuntimeError("write command requires a FREE slot")

        self.pending_write = None
        self.active_write = index
        self.slot_states[index] = SlotState.WRITING
        self.assert_invariants()
        return index

    def complete_write(self, success: object) -> int:
        if not isinstance(success, bool):
            raise TypeError("success must be boolean")
        if self.active_write is None:
            raise RuntimeError("no write is active")

        index = self.active_write
        if self.slot_states[index] is not SlotState.WRITING:
            raise RuntimeError("active write does not own a WRITING slot")

        self.active_write = None
        self.slot_states[index] = SlotState.READY if success else SlotState.FREE
        if not success:
            self.status_write_error = True
            self.pending_write = index
        self.assert_invariants()
        return index

    def accept_read(self) -> int:
        if self.pending_read is None:
            raise RuntimeError("no read command is pending")
        if self.active_read is not None:
            raise RuntimeError("a read is already active")

        index = self.pending_read
        if not self.display_valid or index != self.front_buffer:
            raise RuntimeError("read command does not target a valid front buffer")
        if self.slot_states[index] is not SlotState.READING:
            raise RuntimeError("read command requires a READING slot")

        self.pending_read = None
        self.active_read = index
        self.assert_invariants()
        return index

    def complete_read(self, success: object) -> int:
        if not isinstance(success, bool):
            raise TypeError("success must be boolean")
        if self.active_read is None:
            raise RuntimeError("no read is active")

        index = self.active_read
        self.active_read = None
        self.read_released = True
        if not success:
            self.status_read_error = True
        self.assert_invariants()
        return index

    def _promote_back_buffer(self) -> None:
        old_front = self.front_buffer
        new_front = self.back_buffer
        if self.slot_states[new_front] is not SlotState.READY:
            raise RuntimeError("only a READY back buffer may be promoted")

        self.front_buffer = new_front
        self.back_buffer = old_front
        self.slot_states[new_front] = SlotState.READING
        self.slot_states[old_front] = SlotState.FREE
        self.display_valid = True
        self.read_released = False
        self.pending_read = new_front
        self.pending_write = old_front
        self.swap_count += 1

    def on_vblank(self) -> VBlankAction:
        """Service one vblank after all same-epoch DMA completions retire."""

        if not self.display_valid:
            if self.back_state is SlotState.READY:
                self._promote_back_buffer()
                action = VBlankAction.SWAP
            else:
                action = VBlankAction.BLACK
        elif not self.read_released:
            self.status_read_deadline_miss = True
            action = VBlankAction.DEADLINE_MISS
        elif self.back_state is SlotState.READY:
            self._promote_back_buffer()
            action = VBlankAction.SWAP
        else:
            self.pending_read = self.front_buffer
            self.read_released = False
            self.repeat_count += 1
            action = VBlankAction.REPEAT

        self.assert_invariants()
        return action

    def assert_invariants(self) -> None:
        """Raise when the model reaches an ownership state forbidden by RTL."""

        if self.front_buffer == self.back_buffer:
            raise AssertionError("front and back buffers alias")
        if self.display_valid:
            if self.front_state is not SlotState.READING:
                raise AssertionError("a valid front buffer must be READING")
            if self.back_state is SlotState.READING:
                raise AssertionError("the back buffer cannot be READING")
        elif self.pending_read is not None or self.active_read is not None:
            raise AssertionError("a reader exists before the first promotion")

        if self.pending_write is not None:
            if self.active_write is not None:
                raise AssertionError("write command is pending while a write is active")
            if self.pending_write != self.back_buffer:
                raise AssertionError("pending write does not target the back buffer")
            if self.slot_states[self.pending_write] is not SlotState.FREE:
                raise AssertionError("pending write does not target a FREE slot")
        if self.active_write is not None:
            if self.active_write != self.back_buffer:
                raise AssertionError("active write does not own the back buffer")
            if self.slot_states[self.active_write] is not SlotState.WRITING:
                raise AssertionError("active write slot is not WRITING")
        if self.pending_read is not None:
            if self.active_read is not None:
                raise AssertionError("read command is pending while a read is active")
            if self.pending_read != self.front_buffer:
                raise AssertionError("pending read does not target the front buffer")
            if self.read_released:
                raise AssertionError("pending read cannot be marked released")
        if self.active_read is not None:
            if self.active_read != self.front_buffer:
                raise AssertionError("active read does not own the front buffer")
            if self.slot_states[self.active_read] is not SlotState.READING:
                raise AssertionError("active read slot is not READING")
            if self.read_released:
                raise AssertionError("active read cannot be marked released")
        if (self.display_valid and not self.read_released and self.pending_read is None and self.active_read is None):
            raise AssertionError("unreleased front buffer has no read command")
        if self.active_write is not None and self.active_write == self.active_read:
            raise AssertionError("one slot is owned by both DMA engines")


__all__ = [
    "AXI_ADDR_WIDTH",
    "AXI_BOUNDARY_BYTES",
    "AXI_DATA_BYTES",
    "AxiBurst",
    "BYTES_PER_PIXEL",
    "DMA_BURST_BEATS",
    "DoubleBufferModel",
    "FB0_BASE_ADDR",
    "FB1_BASE_ADDR",
    "FB_SLOT_BYTES",
    "FRAME_HEIGHT",
    "FRAME_WIDTH",
    "FramebufferLayout",
    "FramebufferMemoryModel",
    "STRIDE_BYTES",
    "SlotState",
    "VBlankAction",
    "pack_axi_beat",
    "pack_xrgb8888",
    "plan_axi_bursts",
    "unpack_axi_beat",
    "unpack_xrgb8888",
]
