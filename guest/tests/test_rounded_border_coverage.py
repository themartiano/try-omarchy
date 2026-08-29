#!/usr/bin/env python3
"""Production-bound regression tests for rounded client/border AA coverage.

Hyprland draws the rounded client and its border in separate passes.  These
tests model the alpha math at their shared inner edge and verify that the
reviewed source patch wires that exact model into every supported render path.
They remain deterministic and do not depend on a GPU or screenshot.
"""

from __future__ import annotations

import math
import pathlib
import unittest


# Exact constant from Hyprland v0.56.1's rounding.glsl. The transition spans
# radius +/- this value in framebuffer pixels.
SMOOTHING_CONSTANT = math.pi / 5.34665792551
LEGACY_DIAGONAL_BIAS = math.sqrt(2.0) - 1.0
PATCH = pathlib.Path(__file__).resolve().parents[1] / "patches/hyprland/rounded-border-coverage.patch"


def smoothstep01(value: float) -> float:
    """Match GLSL smoothstep(0.0, 1.0, value)."""
    value = min(1.0, max(0.0, value))
    return value * value * (3.0 - 2.0 * value)


def smoothing_argument(edge_offset: float, edge_bias: float = 0.0) -> float:
    """Return the shader's smoothstep argument relative to the round radius."""
    return (
        edge_offset - edge_bias + SMOOTHING_CONSTANT
    ) / (2.0 * SMOOTHING_CONSTANT)


def client_coverage(edge_offset: float, edge_bias: float = 0.0) -> float:
    """Model roundingWithEdgeBias's alpha multiplier at the client edge."""
    return 1.0 - smoothstep01(smoothing_argument(edge_offset, edge_bias))


def inner_border_coverage(edge_offset: float) -> float:
    """Model the complementary border coverage at its anti-aliased inner edge."""
    return 1.0 - client_coverage(edge_offset)


def source_over_alpha(top: float, bottom: float) -> float:
    """Combine two independently rendered passes with source-over blending."""
    return top + bottom * (1.0 - top)


class RoundedBorderCoverageTests(unittest.TestCase):
    def test_legacy_radius_workaround_still_leaks_background(self) -> None:
        # Hyprland's old R-1 workaround moves a circular corner outward by
        # sqrt(2)-1 pixels on the diagonal. It greatly reduces, but does not
        # eliminate, the two-pass undercoverage at the shared border midpoint.
        client = client_coverage(0.0, LEGACY_DIAGONAL_BIAS)
        border = inner_border_coverage(0.0)
        aggregate = source_over_alpha(border, client)

        self.assertAlmostEqual(client, 0.9411295783578575)
        self.assertEqual(border, 0.5)
        self.assertAlmostEqual(aggregate, 0.9705647891789287)
        self.assertGreater(1.0 - aggregate, 0.0)

    def test_two_smoothing_constants_cover_entire_inner_transition(self) -> None:
        bias = 2.0 * SMOOTHING_CONSTANT
        transition_start = -SMOOTHING_CONSTANT
        transition_end = SMOOTHING_CONSTANT

        # The smoothstep argument is affine and increasing in edge_offset.  Its
        # maximum on the whole inner-AA interval is therefore at transition_end.
        # With a 2*S bias that maximum is exactly zero, so GLSL smoothstep clamps
        # to zero and client coverage is analytically 1.0 everywhere in it.
        self.assertGreater(
            smoothing_argument(transition_end),
            smoothing_argument(transition_start),
        )
        self.assertEqual(smoothing_argument(transition_end, bias), 0.0)

        # Fixed eighth-pixel samples guard the implemented formulas as well as
        # the endpoint argument above proving the continuous interval.
        for eighth in range(-8, 9):
            edge_offset = SMOOTHING_CONSTANT * eighth / 8.0
            with self.subTest(edge_offset=edge_offset):
                client = client_coverage(edge_offset, bias)
                border = inner_border_coverage(edge_offset)
                self.assertEqual(client, 1.0)
                self.assertEqual(source_over_alpha(client, border), 1.0)

    def test_unbiased_shader_path_keeps_ordinary_antialiasing(self) -> None:
        # Unsupported paths get a zero shader bias and retain the legacy radius
        # adjustment in C++. These are exact shader smoothstep values.
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

        self.assertNotEqual(
            client_coverage(0.0),
            client_coverage(0.0, 2.0 * SMOOTHING_CONSTANT),
        )

    def test_three_pixel_border_hides_client_before_outer_antialiasing(self) -> None:
        # The biased client's outer tail ends at R+3*S. The border's outer AA
        # starts at R+B-S, so an integer framebuffer border is safe at B>=3.
        border_thickness = 3.0
        safety_margin = border_thickness - 4.0 * SMOOTHING_CONSTANT

        self.assertGreater(safety_margin, 0.0)
        self.assertEqual(
            client_coverage(border_thickness - SMOOTHING_CONSTANT, 2.0 * SMOOTHING_CONSTANT),
            0.0,
        )

    def test_translucent_omarchy_borders_composite_over_covered_client(self) -> None:
        # Omarchy's stock active and inactive border alphas are 0xee and 0xaa.
        # A translucent border still needs an opaque client underneath its
        # inner AA; otherwise the wallpaper contributes to the final pixel.
        border_coverage = inner_border_coverage(0.0)
        legacy_client = client_coverage(0.0, LEGACY_DIAGONAL_BIAS)
        covered_client = client_coverage(0.0, 2.0 * SMOOTHING_CONSTANT)

        for alpha_byte in (0xEE, 0xAA):
            with self.subTest(alpha_byte=alpha_byte):
                effective_border_alpha = alpha_byte / 255.0 * border_coverage
                self.assertLess(
                    source_over_alpha(effective_border_alpha, legacy_client),
                    1.0,
                )
                self.assertEqual(
                    source_over_alpha(effective_border_alpha, covered_client),
                    1.0,
                )

    def test_patch_wires_guarded_bias_through_all_supported_paths(self) -> None:
        patch_lines = PATCH.read_text().splitlines()
        added = [line[1:] for line in patch_lines if line.startswith("+") and not line.startswith("+++")]
        removed = [line[1:] for line in patch_lines if line.startswith("-") and not line.startswith("---")]
        added_text = "\n".join(added)
        added_stripped = [line.strip() for line in added]
        added_normalized = [" ".join(line.split()) for line in added]

        self.assertEqual(removed.count("    rounding -= 1; // to fix a border issue"), 1)
        self.assertIn("if (!ROUNDING_OVERLAPS_BORDER)", added_stripped)
        self.assertIn("rounding -= 1;", added_stripped)

        for predicate_fragment in (
            "m_data.mainSurface",
            "m_renderData.renderModif.combinedScale()",
            "RENDERED_BORDER_SIZE >= 3 && WINDOWOPAQUE &&",
            "TEXTURE->m_type != TEXTURE_EXTERNAL",
            "ALPHA >= 1.F && OVERALL_ALPHA >= 1.F",
            "including for translucent borders",
        ):
            with self.subTest(predicate_fragment=predicate_fragment):
                self.assertIn(predicate_fragment, added_text)

        self.assertNotIn("BORDEROPAQUE", added_text)
        self.assertNotIn("BORDER_GRADIENT_OPAQUE", added_text)

        self.assertEqual(
            added_normalized.count(".roundingOverlapsBorder = ROUNDING_OVERLAPS_BORDER,"),
            4,
        )
        self.assertEqual(
            added_normalized.count(".roundingOverlapsBorder = data.roundingOverlapsBorder,"),
            3,
        )
        self.assertEqual(
            added_normalized.count(".roundingOverlapsBorder = m_data.roundingOverlapsBorder,"),
            1,
        )
        self.assertEqual(
            added_stripped.count(
                "shader->setUniformInt(SHADER_ROUNDING_OVERLAPS_BORDER, data.roundingOverlapsBorder);"
            ),
            1,
        )

        for shader_fragment in (
            "uniform bool  roundingOverlapsBorder;",
            "float roundingEdgeBias = roundingOverlapsBorder ? SMOOTHING_CONSTANT * 2.0 : 0.0;",
            "pixColor = roundingWithEdgeBias(pixColor, radius, roundingPower, topLeft, fullSize, roundingEdgeBias);",
            "mirrorColor = roundingWithEdgeBias(mirrorColor, radius, roundingPower, topLeft, fullSize, roundingEdgeBias);",
            "return roundingWithEdgeBias(color, radius, roundingPower, topLeft, fullSize, 0.0);",
        ):
            with self.subTest(shader_fragment=shader_fragment):
                self.assertIn(shader_fragment, added_stripped)


if __name__ == "__main__":
    unittest.main()
