"""Bit-accurate golden model for the v1.0 video-processing pipeline.

The model intentionally uses integer arithmetic only.  Its equations, rounding,
threshold scaling, and border policy mirror ``docs/design-spec.md`` and are
designed to be called directly from unit tests or a cocotb scoreboard.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum

import numpy as np


RGB_RED_COEFFICIENT = 77
RGB_GREEN_COEFFICIENT = 150
RGB_BLUE_COEFFICIENT = 29
RGB_ROUNDING_TERM = 128
MAX_CONFIGURATION_VALUE = (1 << 16) - 1
MAX_GRADIENT = 1020
MAX_MAGNITUDE_11BIT = (1 << 11) - 1
MAX_REACHABLE_MAGNITUDE = 1530
DEFAULT_MAX_WIDTH = 1280
DEFAULT_MAX_HEIGHT = 720


class VideoMode(IntEnum):
    """Frame-atomic output modes defined by the v1.0 interface."""

    PASSTHROUGH = 0
    GRAYSCALE = 1
    SOBEL_MAGNITUDE = 2
    BINARY_EDGE = 3


def _integer_scalar(name: str, value: object, minimum: int, maximum: int) -> int:
    if isinstance(value, (bool, np.bool_)) or not isinstance(value, (int, np.integer)):
        raise TypeError(f"{name} must be an integer")

    integer_value = int(value)
    if not minimum <= integer_value <= maximum:
        raise ValueError(f"{name} must be in the range {minimum}..{maximum}")
    return integer_value


@dataclass(frozen=True, slots=True)
class FrameConfig:
    """Configuration sampled atomically for one input frame.

    Zero dimensions are representable by the 16-bit hardware ports so they are
    accepted by this data class.  ``validate_frame_protocol`` reports them as a
    protocol error, while ``process_frame`` rejects them because no legal output
    image exists for an illegal configuration.
    """

    frame_width: int
    frame_height: int
    mode: VideoMode | int = VideoMode.PASSTHROUGH
    threshold: int = 0

    def __post_init__(self) -> None:
        width = _integer_scalar("frame_width", self.frame_width, 0, MAX_CONFIGURATION_VALUE)
        height = _integer_scalar("frame_height", self.frame_height, 0, MAX_CONFIGURATION_VALUE)
        threshold = _integer_scalar("threshold", self.threshold, 0, 255)
        mode_value = _integer_scalar("mode", self.mode, 0, 3)

        object.__setattr__(self, "frame_width", width)
        object.__setattr__(self, "frame_height", height)
        object.__setattr__(self, "threshold", threshold)
        object.__setattr__(self, "mode", VideoMode(mode_value))


@dataclass(frozen=True, slots=True)
class FrameResult:
    """Expected frame output and AXI4-Stream Video marker locations."""

    pixels: np.ndarray
    sof: np.ndarray
    eol: np.ndarray
    width: int
    height: int
    status_protocol_error: bool


def _integer_array(name: str, values: object) -> np.ndarray:
    array = np.asarray(values)
    if not np.issubdtype(array.dtype, np.integer):
        raise TypeError(f"{name} must contain integer values")
    return array


def _unsigned_array(
    name: str,
    values: object,
    maximum: int,
) -> np.ndarray:
    array = _integer_array(name, values)
    if array.size and (np.any(array < 0) or np.any(array > maximum)):
        raise ValueError(f"{name} values must be in the range 0..{maximum}")
    return array


def _rgb_array(rgb: object, *, require_frame: bool) -> np.ndarray:
    array = _unsigned_array("rgb", rgb, 255)
    if require_frame:
        if array.ndim != 3 or array.shape[2] != 3:
            raise ValueError("rgb frame must have shape (height, width, 3)")
    elif array.ndim < 1 or array.shape[-1] != 3:
        raise ValueError("rgb values must have a final channel dimension of 3")
    return array.astype(np.uint8, copy=False)


def _gray_array(gray: object) -> np.ndarray:
    array = _unsigned_array("gray", gray, 255)
    if array.ndim != 2:
        raise ValueError("gray frame must have shape (height, width)")
    return array.astype(np.uint8, copy=False)


def _validate_maxima(max_width: object, max_height: object) -> tuple[int, int]:
    width = _integer_scalar("max_width", max_width, 3, MAX_CONFIGURATION_VALUE)
    height = _integer_scalar("max_height", max_height, 1, MAX_CONFIGURATION_VALUE)
    return width, height


def rgb_to_gray(rgb: object) -> np.ndarray:
    """Convert RGB888 values to unsigned 8-bit grayscale.

    The final dimension is ordered R, G, B.  The result is exactly
    ``(77*R + 150*G + 29*B + 128) >> 8``; there is deliberately no saturation
    branch because the coefficients sum to 256.
    """

    rgb_u8 = _rgb_array(rgb, require_frame=False)
    wide_rgb = rgb_u8.astype(np.uint32)

    weighted_sum = (
        RGB_RED_COEFFICIENT * wide_rgb[..., 0]
        + RGB_GREEN_COEFFICIENT * wide_rgb[..., 1]
        + RGB_BLUE_COEFFICIENT * wide_rgb[..., 2]
        + RGB_ROUNDING_TERM
    )

    # This bound is the software equivalent of the RTL width proof.
    if weighted_sum.size and int(weighted_sum.max()) > 0xFFFF:
        raise AssertionError("grayscale weighted sum exceeded 16 bits")

    return (weighted_sum >> 8).astype(np.uint8)


def sobel_gradients(gray: object) -> tuple[np.ndarray, np.ndarray]:
    """Return signed Gx and Gy arrays for a centered 3x3 Sobel window.

    Border gradients are defined as zero.  Therefore a frame smaller than 3x3
    returns all-zero gradients, matching the legal tiny-frame policy.
    """

    gray_u8 = _gray_array(gray)
    source = gray_u8.astype(np.int32)
    height, width = source.shape
    gx = np.zeros((height, width), dtype=np.int16)
    gy = np.zeros((height, width), dtype=np.int16)

    if height < 3 or width < 3:
        return gx, gy

    p00 = source[:-2, :-2]
    p01 = source[:-2, 1:-1]
    p02 = source[:-2, 2:]
    p10 = source[1:-1, :-2]
    p12 = source[1:-1, 2:]
    p20 = source[2:, :-2]
    p21 = source[2:, 1:-1]
    p22 = source[2:, 2:]

    gx_interior = -p00 + p02 - (2 * p10) + (2 * p12) - p20 + p22
    gy_interior = p00 + (2 * p01) + p02 - p20 - (2 * p21) - p22

    if np.any(np.abs(gx_interior) > MAX_GRADIENT) or np.any(np.abs(gy_interior) > MAX_GRADIENT):
        raise AssertionError("Sobel gradient exceeded the legal signed range")

    gx[1:-1, 1:-1] = gx_interior.astype(np.int16)
    gy[1:-1, 1:-1] = gy_interior.astype(np.int16)
    return gx, gy


def sobel_magnitude(
    gx: object,
    gy: object,
) -> tuple[np.ndarray, np.ndarray]:
    """Return the 11-bit L1 magnitude and its saturated 8-bit value."""

    gx_array = _integer_array("gx", gx)
    gy_array = _integer_array("gy", gy)
    if gx_array.shape != gy_array.shape:
        raise ValueError("gx and gy must have matching shapes")
    if gx_array.size and (
        np.any(gx_array < -MAX_GRADIENT)
        or np.any(gx_array > MAX_GRADIENT)
        or np.any(gy_array < -MAX_GRADIENT)
        or np.any(gy_array > MAX_GRADIENT)
    ):
        raise ValueError("gx and gy values must be in the range -1020..1020")

    magnitude_wide = np.abs(gx_array.astype(np.int32)) + np.abs(gy_array.astype(np.int32))
    if magnitude_wide.size and np.any(magnitude_wide > MAX_MAGNITUDE_11BIT):
        raise AssertionError("Sobel magnitude exceeded 11-bit storage")

    magnitude_11bit = magnitude_wide.astype(np.uint16)
    magnitude_8bit = np.minimum(magnitude_11bit, 255).astype(np.uint8)
    return magnitude_11bit, magnitude_8bit


def threshold_edges(magnitude_11bit: object, threshold: object) -> np.ndarray:
    """Apply the strict ``magnitude > threshold*6`` edge comparison."""

    magnitude = _unsigned_array("magnitude_11bit", magnitude_11bit, MAX_MAGNITUDE_11BIT).astype(np.uint16, copy=False)
    threshold_u8 = _integer_scalar("threshold", threshold, 0, 255)
    threshold_11bit = threshold_u8 * 6
    return np.where(magnitude > threshold_11bit, 255, 0).astype(np.uint8)


def expected_markers(width: object, height: object) -> tuple[np.ndarray, np.ndarray]:
    """Return the expected SOF and EOL maps for a legal raster frame."""

    frame_width = _integer_scalar("width", width, 1, MAX_CONFIGURATION_VALUE)
    frame_height = _integer_scalar("height", height, 1, MAX_CONFIGURATION_VALUE)

    sof = np.zeros((frame_height, frame_width), dtype=np.bool_)
    eol = np.zeros((frame_height, frame_width), dtype=np.bool_)
    sof[0, 0] = True
    eol[:, -1] = True
    return sof, eol


def _binary_marker_array(name: str, marker: object) -> np.ndarray:
    array = np.asarray(marker)
    if not (np.issubdtype(array.dtype, np.bool_) or np.issubdtype(array.dtype, np.integer)):
        raise TypeError(f"{name} must contain boolean or integer marker values")
    if array.size and np.any((array != 0) & (array != 1)):
        raise ValueError(f"{name} marker values must be zero or one")
    return array.astype(np.bool_, copy=False)


def validate_frame_protocol(
    config: FrameConfig,
    input_sof: object,
    input_eol: object,
    *,
    max_width: object = DEFAULT_MAX_WIDTH,
    max_height: object = DEFAULT_MAX_HEIGHT,
) -> bool:
    """Return whether one raster frame violates the framing contract.

    This frame-level checker covers illegal dimensions, missing or unexpected
    SOF, early or missing EOL, and a pixel-count mismatch relative to the
    committed dimensions.  A scoreboard keeps the returned status sticky by
    OR-ing it with its previous status until reset.
    """

    if not isinstance(config, FrameConfig):
        raise TypeError("config must be a FrameConfig")

    legal_max_width, legal_max_height = _validate_maxima(max_width, max_height)
    width = config.frame_width
    height = config.frame_height
    if (width == 0 or height == 0 or width > legal_max_width or height > legal_max_height):
        return True

    sof = _binary_marker_array("input_sof", input_sof)
    eol = _binary_marker_array("input_eol", input_eol)
    expected_shape = (height, width)
    if sof.shape != expected_shape or eol.shape != expected_shape:
        return True

    expected_sof, expected_eol = expected_markers(width, height)
    return bool(
        np.any(sof != expected_sof)
        or np.any(eol != expected_eol)
    )


def process_frame(
    rgb_frame: object,
    config: FrameConfig,
    *,
    input_sof: object | None = None,
    input_eol: object | None = None,
    prior_protocol_error: bool = False,
    max_width: object = DEFAULT_MAX_WIDTH,
    max_height: object = DEFAULT_MAX_HEIGHT,
) -> FrameResult:
    """Run a legal RGB frame through all v1.0 algorithm stages.

    ``config`` represents the values sampled at the accepted SOF.  Supplying
    input marker maps also evaluates the frame-level protocol status; the
    returned marker maps are always the expected legal output locations.
    """

    if not isinstance(config, FrameConfig):
        raise TypeError("config must be a FrameConfig")
    if not isinstance(prior_protocol_error, (bool, np.bool_)):
        raise TypeError("prior_protocol_error must be boolean")

    legal_max_width, legal_max_height = _validate_maxima(max_width, max_height)
    if (config.frame_width == 0
        or config.frame_height == 0
        or config.frame_width > legal_max_width
        or config.frame_height > legal_max_height
    ):
        raise ValueError("configuration dimensions do not describe a legal frame")

    rgb_u8 = _rgb_array(rgb_frame, require_frame=True)
    expected_shape = (config.frame_height, config.frame_width, 3)
    if rgb_u8.shape != expected_shape:
        raise ValueError(
            f"rgb frame shape {rgb_u8.shape} does not match configuration "
            f"{expected_shape}"
        )

    if (input_sof is None) != (input_eol is None):
        raise ValueError("input_sof and input_eol must be supplied together")

    gray = rgb_to_gray(rgb_u8)
    gx, gy = sobel_gradients(gray)
    magnitude_11bit, magnitude_8bit = sobel_magnitude(gx, gy)
    if magnitude_11bit.size and np.any(
        magnitude_11bit > MAX_REACHABLE_MAGNITUDE
    ):
        raise AssertionError("image-derived Sobel magnitude exceeded 1530")
    edge = threshold_edges(magnitude_11bit, config.threshold)

    if config.mode is VideoMode.PASSTHROUGH:
        output = rgb_u8.copy()
    elif config.mode is VideoMode.GRAYSCALE:
        output = np.repeat(gray[..., np.newaxis], 3, axis=2)
    elif config.mode is VideoMode.SOBEL_MAGNITUDE:
        output = np.repeat(magnitude_8bit[..., np.newaxis], 3, axis=2)
    else:
        output = np.repeat(edge[..., np.newaxis], 3, axis=2)

    output_sof, output_eol = expected_markers(config.frame_width, config.frame_height)
    current_protocol_error = False
    if input_sof is not None:
        current_protocol_error = validate_frame_protocol(
            config,
            input_sof,
            input_eol,
            max_width=legal_max_width,
            max_height=legal_max_height,
        )

    return FrameResult(
        pixels=output,
        sof=output_sof,
        eol=output_eol,
        width=config.frame_width,
        height=config.frame_height,
        status_protocol_error=bool(prior_protocol_error or current_protocol_error),
    )


__all__ = [
    "FrameConfig",
    "FrameResult",
    "VideoMode",
    "expected_markers",
    "process_frame",
    "rgb_to_gray",
    "sobel_gradients",
    "sobel_magnitude",
    "threshold_edges",
    "validate_frame_protocol",
]
