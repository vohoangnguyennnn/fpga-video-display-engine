import unittest

import numpy as np

from models.video_model import (
    FrameConfig,
    VideoMode,
    expected_markers,
    process_frame,
    rgb_to_gray,
    sobel_gradients,
    sobel_magnitude,
    threshold_edges,
    validate_frame_protocol,
)


class VideoModelTest(unittest.TestCase):
    def test_rgb_to_gray_coefficients_and_rounding(self) -> None:
        rgb = np.array(
            [
                [0, 0, 0],
                [255, 255, 255],
                [255, 0, 0],
                [0, 255, 0],
                [0, 0, 255],
                [0, 0, 4],
                [0, 0, 5],
            ],
            dtype=np.uint8,
        )

        expected = np.array([0, 255, 77, 149, 29, 0, 1], dtype=np.uint8)
        np.testing.assert_array_equal(rgb_to_gray(rgb), expected)

    def test_sobel_signed_extrema_magnitude_and_border(self) -> None:
        gray = np.array(
            [
                [0, 255, 255],
                [0, 0, 255],
                [0, 0, 0],
            ],
            dtype=np.uint8,
        )

        gx, gy = sobel_gradients(gray)
        self.assertEqual(int(gx[1, 1]), 765)
        self.assertEqual(int(gy[1, 1]), 765)
        self.assertTrue(np.all(gx[[0, 2], :] == 0))
        self.assertTrue(np.all(gx[:, [0, 2]] == 0))
        self.assertTrue(np.all(gy[[0, 2], :] == 0))
        self.assertTrue(np.all(gy[:, [0, 2]] == 0))

        magnitude_11bit, magnitude_8bit = sobel_magnitude(gx, gy)
        self.assertEqual(int(magnitude_11bit[1, 1]), 1530)
        self.assertEqual(int(magnitude_8bit[1, 1]), 255)

        inverse_gx, inverse_gy = sobel_gradients(255 - gray)
        self.assertEqual(int(inverse_gx[1, 1]), -765)
        self.assertEqual(int(inverse_gy[1, 1]), -765)

    def test_threshold_is_scaled_strict_and_unsigned(self) -> None:
        magnitude = np.array([0, 5, 6, 7, 1530], dtype=np.uint16)
        np.testing.assert_array_equal(
            threshold_edges(magnitude, 1),
            np.array([0, 0, 0, 255, 255], dtype=np.uint8),
        )
        np.testing.assert_array_equal(
            threshold_edges(magnitude, 0),
            np.array([0, 255, 255, 255, 255], dtype=np.uint8),
        )
        np.testing.assert_array_equal(
            threshold_edges(magnitude, 255),
            np.zeros(5, dtype=np.uint8),
        )

    def test_seeded_frame_matches_scalar_equations(self) -> None:
        rng = np.random.default_rng(0x5EED)
        rgb = rng.integers(0, 256, size=(5, 7, 3), dtype=np.uint8)

        expected_gray = np.zeros((5, 7), dtype=np.uint8)
        for y in range(5):
            for x in range(7):
                red, green, blue = (int(channel) for channel in rgb[y, x])
                expected_gray[y, x] = ((77 * red) + (150 * green) + (29 * blue) + 128) >> 8
        np.testing.assert_array_equal(rgb_to_gray(rgb), expected_gray)

        expected_gx = np.zeros((5, 7), dtype=np.int16)
        expected_gy = np.zeros((5, 7), dtype=np.int16)
        for y in range(1, 4):
            for x in range(1, 6):
                window = expected_gray[y - 1 : y + 2, x - 1 : x + 2]
                p00, p01, p02 = (int(value) for value in window[0])
                p10, _, p12 = (int(value) for value in window[1])
                p20, p21, p22 = (int(value) for value in window[2])
                expected_gx[y, x] = (-p00 + p02 - (2 * p10) + (2 * p12) - p20 + p22)
                expected_gy[y, x] = (p00 + (2 * p01) + p02 - p20 - (2 * p21) - p22)

        gx, gy = sobel_gradients(rgb_to_gray(rgb))
        np.testing.assert_array_equal(gx, expected_gx)
        np.testing.assert_array_equal(gy, expected_gy)

    def test_all_output_modes_and_marker_locations(self) -> None:
        gray_pattern = np.array(
            [
                [0, 255, 255],
                [0, 0, 255],
                [0, 0, 0],
            ],
            dtype=np.uint8,
        )
        rgb = np.repeat(gray_pattern[..., np.newaxis], 3, axis=2)

        passthrough = process_frame(
            rgb,
            FrameConfig(3, 3, VideoMode.PASSTHROUGH, 0),
        )
        np.testing.assert_array_equal(passthrough.pixels, rgb)

        grayscale = process_frame(
            rgb,
            FrameConfig(3, 3, VideoMode.GRAYSCALE, 0),
        )
        np.testing.assert_array_equal(grayscale.pixels, rgb)

        magnitude = process_frame(
            rgb,
            FrameConfig(3, 3, VideoMode.SOBEL_MAGNITUDE, 0),
        )
        expected_magnitude = np.zeros((3, 3, 3), dtype=np.uint8)
        expected_magnitude[1, 1, :] = 255
        np.testing.assert_array_equal(magnitude.pixels, expected_magnitude)

        edge = process_frame(
            rgb,
            FrameConfig(3, 3, VideoMode.BINARY_EDGE, 254),
        )
        np.testing.assert_array_equal(edge.pixels, expected_magnitude)

        disabled_edge = process_frame(
            rgb,
            FrameConfig(3, 3, VideoMode.BINARY_EDGE, 255),
        )
        np.testing.assert_array_equal(
            disabled_edge.pixels,
            np.zeros((3, 3, 3), dtype=np.uint8),
        )

        expected_sof, expected_eol = expected_markers(3, 3)
        np.testing.assert_array_equal(edge.sof, expected_sof)
        np.testing.assert_array_equal(edge.eol, expected_eol)
        self.assertEqual(edge.width, 3)
        self.assertEqual(edge.height, 3)
        self.assertFalse(edge.status_protocol_error)

    def test_tiny_frames_have_zero_sobel_outputs(self) -> None:
        rgb = np.array([[[12, 34, 56]]], dtype=np.uint8)

        magnitude = process_frame(
            rgb,
            FrameConfig(1, 1, VideoMode.SOBEL_MAGNITUDE, 0),
        )
        edge = process_frame(
            rgb,
            FrameConfig(1, 1, VideoMode.BINARY_EDGE, 0),
        )
        np.testing.assert_array_equal(
            magnitude.pixels, np.zeros((1, 1, 3), dtype=np.uint8)
        )
        np.testing.assert_array_equal(
            edge.pixels, np.zeros((1, 1, 3), dtype=np.uint8)
        )
        self.assertTrue(bool(magnitude.sof[0, 0]))
        self.assertTrue(bool(magnitude.eol[0, 0]))

    def test_frame_protocol_validation_and_sticky_status(self) -> None:
        config = FrameConfig(3, 2, VideoMode.PASSTHROUGH, 0)
        sof, eol = expected_markers(3, 2)
        self.assertFalse(validate_frame_protocol(config, sof, eol))

        missing_sof = sof.copy()
        missing_sof[0, 0] = False
        self.assertTrue(validate_frame_protocol(config, missing_sof, eol))

        early_eol = eol.copy()
        early_eol[0, 1] = True
        self.assertTrue(validate_frame_protocol(config, sof, early_eol))

        self.assertTrue(
            validate_frame_protocol(
                FrameConfig(0, 2),
                np.zeros((2, 1), dtype=np.bool_),
                np.zeros((2, 1), dtype=np.bool_),
            )
        )
        self.assertTrue(
            validate_frame_protocol(
                FrameConfig(9, 2),
                np.zeros((2, 9), dtype=np.bool_),
                np.zeros((2, 9), dtype=np.bool_),
                max_width=8,
                max_height=6,
            )
        )

        rgb = np.zeros((2, 3, 3), dtype=np.uint8)
        result = process_frame(
            rgb,
            config,
            input_sof=sof,
            input_eol=early_eol,
        )
        self.assertTrue(result.status_protocol_error)

        sticky_result = process_frame(
            rgb,
            config,
            input_sof=sof,
            input_eol=eol,
            prior_protocol_error=True,
        )
        self.assertTrue(sticky_result.status_protocol_error)

    def test_invalid_inputs_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            FrameConfig(3, 3, mode=4)
        with self.assertRaises(ValueError):
            FrameConfig(3, 3, threshold=256)
        with self.assertRaises(TypeError):
            rgb_to_gray(np.array([[0.0, 0.0, 0.0]]))
        with self.assertRaises(ValueError):
            process_frame(
                np.zeros((2, 3, 3), dtype=np.uint8),
                FrameConfig(3, 3),
            )
        with self.assertRaises(ValueError):
            process_frame(
                np.zeros((1, 1, 3), dtype=np.uint8),
                FrameConfig(0, 1),
            )


if __name__ == "__main__":
    unittest.main()
