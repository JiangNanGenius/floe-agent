// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import com.floe.android.feature.workbench.NormalizedRect
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Crop expressed in Media3's normalized device coordinates (-1..1). */
internal data class NdcCrop(
    val left: Float,
    val right: Float,
    val bottom: Float,
    val top: Float,
) {
    val isUnit: Boolean
        get() = abs(left + 1f) < 0.0001f && abs(right - 1f) < 0.0001f &&
            abs(bottom + 1f) < 0.0001f && abs(top - 1f) < 0.0001f
}

/**
 * Pure mapping of the shared top-leading normalized crop rectangle into
 * Media3 `Crop` NDC. Crop is applied before rotation and aspect-fit, matching
 * `WorkbenchClipGeometry.make` (crop in display coordinates, then user
 * rotation about the crop center, then aspect-fit into the canvas).
 */
internal fun cropToNdc(crop: NormalizedRect): NdcCrop {
    val x0 = crop.x.coerceIn(0.0, 1.0)
    val y0 = crop.y.coerceIn(0.0, 1.0)
    val x1 = (crop.x + crop.width).coerceIn(0.0, 1.0)
    val y1 = (crop.y + crop.height).coerceIn(0.0, 1.0)
    return NdcCrop(
        left = (-1.0 + 2.0 * x0).toFloat(),
        right = (-1.0 + 2.0 * x1).toFloat(),
        bottom = (1.0 - 2.0 * y1).toFloat(),
        top = (1.0 - 2.0 * y0).toFloat(),
    )
}

/**
 * Media3's `ScaleAndRotateTransformation` is counter-clockwise. The shared
 * project value is a clockwise UI rotation, so the effect receives its
 * negative; the builder normalizes to [0, 360). Returning exactly 0 skips the
 * effect.
 */
internal fun media3RotationDegrees(clockwiseDegrees: Double): Float {
    if (!clockwiseDegrees.isFinite()) return 0f
    var normalized = clockwiseDegrees % 360.0
    if (normalized < 0) normalized += 360.0
    if (normalized < 0.0001 || abs(normalized - 360.0) < 0.0001) return 0f
    return (-normalized).toFloat()
}

/**
 * Quality (0.01..1) to a concrete H.264/HEVC bitrate. This is a deterministic
 * mapping, not a promise of perceptual parity with AVAssetExportSession; the
 * actual encoder capability is checked before export.
 */
internal fun videoBitrate(width: Int, height: Int, frameRate: Double, quality: Double): Int {
    val bpp = 0.02 + quality.coerceIn(0.01, 1.0) * 0.18
    val raw = width.toDouble() * height.toDouble() * max(1.0, frameRate) * bpp
    return raw.roundToInt().coerceIn(500_000, 80_000_000)
}

/** Aspect-fit size for the image renderer and tests. */
internal fun fitInto(
    sourceWidth: Double,
    sourceHeight: Double,
    canvasWidth: Double,
    canvasHeight: Double,
): Pair<Double, Double> {
    if (sourceWidth <= 0.0 || sourceHeight <= 0.0 || canvasWidth <= 0.0 || canvasHeight <= 0.0) {
        return 0.0 to 0.0
    }
    val scale = min(canvasWidth / sourceWidth, canvasHeight / sourceHeight)
    return (sourceWidth * scale) to (sourceHeight * scale)
}
