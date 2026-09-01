#!/usr/bin/env python3
"""Regression tests for rounded client/border coverage under Omarchy opacity.

Hyprland renders the client and border in separate passes. Omarchy then applies
0.985/0.96 compositor opacity to normal windows. These tests model both rounded
masks and verify that the source patch is wired through every texture path.
"""

from __future__ import annotations

import math
import pathlib
import unittest


SMOOTHING_CONSTANT = math.pi / 5.34665792551
PATCH = pathlib.Path(__file__).resolve().parents[1] / "patches/hyprland/rounded-border-coverage.patch"


def smoothstep(edge0: float, edge1: float, value: float) -> float:
    value = min(1.0, max(0.0, (value - edge0) / (edge1 - edge0)))
    return value * value * (3.0 - 2.0 * value)


def client_coverage(edge_offset: float, border_size: float = 0.0) -> float:
    """Model roundingWithBorderCoverage at a signed client-edge distance."""
    if border_size > 0.0:
        fade_start = SMOOTHING_CONSTANT
        fade_end = min(
            SMOOTHING_CONSTANT * 3.0,
            border_size - SMOOTHING_CONSTANT,
        )
    else:
        fade_start = -SMOOTHING_CONSTANT
        fade_end = SMOOTHING_CONSTANT
    return 1.0 - smoothstep(fade_start, fade_end, edge_offset)


def border_annulus_coverage(
    inner_distance: float,
    outer_distance: float,
) -> float:
    inner = smoothstep(
        -SMOOTHING_CONSTANT,
        SMOOTHING_CONSTANT,
        inner_distance,
    )
    outer = 1.0 - smoothstep(
        -SMOOTHING_CONSTANT,
        SMOOTHING_CONSTANT,
        outer_distance,
    )
    return inner * outer


def circular_corner_coverage(
    x: float,
    y: float,
    *,
    top_left: float = 20.0,
    outer_radius: float = 20.0,
    border_size: float = 4.0,
) -> float:
    """Model the patched border shader for one circular top-left corner."""
    px = max(outer_radius - (x - top_left), 0.0)
    py = max(outer_radius - (y - top_left), 0.0)
    distance = math.hypot(px, py)
    return border_annulus_coverage(
        distance - (outer_radius - border_size),
        distance - outer_radius,
    )


def source_over_alpha(top: float, bottom: float) -> float:
    return top + bottom * (1.0 - top)


class RoundedBorderCoverageTests(unittest.TestCase):
    def test_ordinary_rounding_keeps_upstream_antialiasing(self) -> None:
        samples = (
            (-SMOOTHING_CONSTANT, 1.0),
            (-SMOOTHING_CONSTANT / 2.0, 0.84375),
            (0.0, 0.5),
            (SMOOTHING_CONSTANT / 2.0, 0.15625),
            (SMOOTHING_CONSTANT, 0.0),
        )
        for edge_offset, expected in samples:
            with self.subTest(edge_offset=edge_offset):
                self.assertEqual(client_coverage(edge_offset), expected)

    def test_client_fully_covers_border_inner_antialiasing(self) -> None:
        for border_size in (2.0, 3.0, 4.0):
            with self.subTest(border_size=border_size):
                for eighth in range(-8, 9):
                    edge_offset = SMOOTHING_CONSTANT * eighth / 8.0
                    self.assertEqual(
                        client_coverage(edge_offset, border_size),
                        1.0,
                    )

                # The client is gone as soon as the inner edge is safely
                # covered, and always before the border's outer AA starts.
                fade_end = min(
                    SMOOTHING_CONSTANT * 3.0,
                    border_size - SMOOTHING_CONSTANT,
                )
                self.assertEqual(
                    client_coverage(fade_end, border_size),
                    0.0,
                )

    def test_branchless_annulus_has_no_radial_hole(self) -> None:
        inner_radius = 16.0
        outer_radius = 20.0

        # Between both AA transitions, the corner band is continuously solid.
        start = inner_radius + SMOOTHING_CONSTANT
        end = outer_radius - SMOOTHING_CONSTANT
        for sixteenth in range(17):
            distance = start + (end - start) * sixteenth / 16.0
            with self.subTest(distance=distance):
                self.assertEqual(
                    border_annulus_coverage(
                        distance - inner_radius,
                        distance - outer_radius,
                    ),
                    1.0,
                )

    def test_branchless_annulus_fills_the_reported_corner_pixels(self) -> None:
        # The report is a scale-2 render: outer box (20,20), client box
        # (24,24), R=20 and B=4. The old screenshot leaked wallpaper through
        # this exact row. These framebuffer pixel centers must be in the band.
        for x in (28.5, 29.5, 30.5, 31.5, 32.5, 33.5):
            with self.subTest(x=x):
                self.assertGreater(
                    circular_corner_coverage(x, 24.5),
                    0.5,
                )

    def test_omarchy_window_opacity_no_longer_creates_undercoverage(self) -> None:
        # Omarchy tags normal windows with 0.985 active / 0.96 inactive
        # compositor opacity. Those values made both old predicates false.
        for window_alpha, border_alpha in ((0.985, 0xEE / 255), (0.96, 0xAA / 255)):
            with self.subTest(window_alpha=window_alpha):
                self.assertFalse(window_alpha >= 1.0)

                # At the inner AA midpoint the patched opaque client coverage
                # is full. The translucent border can no longer reveal more
                # wallpaper than the configured whole-window opacity.
                effective_border = window_alpha * border_alpha * 0.5
                aggregate = source_over_alpha(
                    effective_border,
                    window_alpha,
                )
                self.assertGreaterEqual(aggregate, window_alpha)
                self.assertLess(aggregate - window_alpha, 0.015)

    def test_patch_wires_content_coverage_through_all_texture_paths(self) -> None:
        patch_lines = PATCH.read_text().splitlines()
        added = [
            line[1:]
            for line in patch_lines
            if line.startswith("+") and not line.startswith("+++")
        ]
        removed = [
            line[1:]
            for line in patch_lines
            if line.startswith("-") and not line.startswith("---")
        ]
        added_text = "\n".join(added)
        added_stripped = [line.strip() for line in added]
        added_normalized = [" ".join(line.split()) for line in added]

        self.assertEqual(
            removed.count("    rounding -= 1; // to fix a border issue"),
            1,
        )
        for fragment in (
            "0.985/0.96 compositor opacity",
            "SURFACE_CONTENT_OPAQUE",
            "SURFACE_COVERS_WINDOW_EDGE",
            "inverseOpaque.empty()",
            "m_data.mainSurface",
            "RENDERED_BORDER_SIZE >= 2",
            "ROUNDING_BORDER_SIZE <= 0.F",
            "roundingWithBorderCoverage",
            "min(SMOOTHING_CONSTANT * 3.0, borderSize - SMOOTHING_CONSTANT)",
            "uniform float roundingBorderSize;",
            "innerCoverage * outerCoverage",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, added_text)

        self.assertIn(
            "diff --git a/src/render/shaders/glsl/ext.frag b/src/render/shaders/glsl/ext.frag",
            PATCH.read_text(),
        )

        self.assertNotIn("roundingWithEdgeBias", added_text)
        self.assertNotIn("ALPHA >= 1.F", added_text)
        self.assertEqual(
            added_normalized.count(
                ".roundingBorderSize = ROUNDING_BORDER_SIZE,"
            ),
            4,
        )
        self.assertEqual(
            added_normalized.count(
                ".roundingBorderSize = data.roundingBorderSize,"
            ),
            3,
        )
        self.assertEqual(
            added_normalized.count(
                ".roundingBorderSize = m_data.roundingBorderSize,"
            ),
            1,
        )
        self.assertEqual(
            added_stripped.count(
                "shader->setUniformFloat(SHADER_ROUNDING_BORDER_SIZE, data.roundingBorderSize);"
            ),
            1,
        )

        for shader_fragment in (
            "pixColor = roundingWithBorderCoverage(pixColor, radius, roundingPower, topLeft, fullSize, roundingBorderSize);",
            "mirrorColor = roundingWithBorderCoverage(mirrorColor, radius, roundingPower, topLeft, fullSize, roundingBorderSize);",
            "return roundingWithBorderCoverage(color, radius, roundingPower, topLeft, fullSize, 0.0);",
        ):
            with self.subTest(shader_fragment=shader_fragment):
                self.assertIn(shader_fragment, added_stripped)


if __name__ == "__main__":
    unittest.main()
