"""Image-level scoreboard backed by the repository's NumPy golden model."""

from __future__ import annotations

from models.video_model import FrameResult

from .axi_video import AxiVideoBeat


def expected_beats(result: FrameResult) -> list[AxiVideoBeat]:
    """Convert a golden-model result into expected output transfers."""

    beats: list[AxiVideoBeat] = []
    for y in range(result.height):
        for x in range(result.width):
            red, green, blue = (int(channel) for channel in result.pixels[y, x])
            beats.append(
                AxiVideoBeat(
                    data=(red << 16) | (green << 8) | blue,
                    sof=bool(result.sof[y, x]),
                    eol=bool(result.eol[y, x]),
                )
            )
    return beats


def check_frame(
    actual: list[AxiVideoBeat],
    result: FrameResult,
    *,
    label: str,
) -> None:
    """Check every pixel and marker with a coordinate-focused failure."""

    expected = expected_beats(result)
    assert len(actual) == len(expected), (
        f"{label}: expected {len(expected)} transfers, received {len(actual)}"
    )

    for index, (observed, reference) in enumerate(zip(actual, expected)):
        if observed != reference:
            y, x = divmod(index, result.width)
            raise AssertionError(
                f"{label}: mismatch at ({x}, {y}): "
                f"expected={reference}, observed={observed}"
            )
