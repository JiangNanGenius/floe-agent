// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import kotlin.math.min

/** A source range used as invisible video clock coverage. */
internal data class CoverageSegment(
    val startUs: Long,
    val endUs: Long,
) {
    val durationUs: Long get() = endUs - startUs
}

/**
 * Media3 renders a video sequence gap as 30 fps SRGB_BT709_FULL blank frames.
 * In a multi-sequence composition that filler would both drive the primary
 * clock for a 50/60 fps export and violate the compositor's one-ColorInfo
 * rule, so every lane gap is covered with real (alpha-zero) frames taken from
 * one of the timeline's own source ranges. These pure source segments are
 * looped until the exact gap duration is covered; they never touch the project
 * files or invent a new asset.
 */
internal object CompositionCoverage {
    fun segments(
        gapDurationUs: Long,
        sourceStartUs: Long,
        sourceEndUs: Long,
    ): List<CoverageSegment> {
        if (gapDurationUs <= 0L) return emptyList()
        val sourceDurationUs = sourceEndUs - sourceStartUs
        if (sourceDurationUs <= 0L) return emptyList()
        val result = ArrayList<CoverageSegment>()
        var remaining = gapDurationUs
        var cursor = sourceStartUs
        while (remaining > 0L) {
            if (cursor >= sourceEndUs) cursor = sourceStartUs
            val available = sourceEndUs - cursor
            if (available <= 0L) return emptyList()
            val take = min(remaining, available)
            result += CoverageSegment(cursor, cursor + take)
            remaining -= take
            cursor += take
        }
        return result
    }
}
