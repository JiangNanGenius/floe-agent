// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import com.floe.android.core.workbenchmedia.timeline.DissolveWindow
import com.floe.android.core.workbenchmedia.util.INVALID_PAYLOAD
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_TRANSITION
import com.floe.android.core.workbenchmedia.util.refusal
import kotlin.math.max
import kotlin.math.min

/** One clip's exact interval on the composition timeline. */
internal data class LayoutInput(
    val clipID: String,
    val startSeconds: Double,
    val endSeconds: Double,
) {
    val durationSeconds: Double get() = endSeconds - startSeconds
}

/**
 * Two-lane compositor plan shared by the retained `CompositionPlayer` preview
 * and `Transformer` export.
 *
 * Media3's `DefaultVideoCompositor` composites one video input per
 * `EditedMediaItemSequence` and treats the first input as the primary stream
 * drawn on top. Lane 0 therefore contains the first clip and is always the
 * primary/top input; lane 1 is the bottom input. Clips assigned to one lane
 * never overlap, so the two sequences can represent every pairwise
 * cross-dissolve without duplicating samples or using a negative gap.
 *
 * The alpha rule compensates Media3's source-over blending (it is NOT an
 * additive blend like the iOS Core Image compositor):
 *  - when the outgoing clip is on top, its opacity ramps 1 -> 0 while the
 *    incoming clip underneath stays at 1;
 *  - when the incoming clip is on top, its opacity ramps 0 -> 1 while the
 *    outgoing clip underneath stays at 1.
 * Both cases produce `(1-p)*outgoing + p*incoming`.
 */
internal data class CompositionLayout(
    val lanes: List<List<String>>,
    val laneOf: Map<String, Int>,
    val inputs: Map<String, LayoutInput>,
    val dissolves: List<DissolveWindow>,
) {
    val usesCompositor: Boolean get() = dissolves.isNotEmpty()
}

internal object CompositionLayoutMath {
    private const val EPSILON = 0.000001

    /**
     * Greedily assigns clips to the two compositor lanes. A clip that overlaps
     * two already-live clips (or a third simultaneous transition) cannot be
     * represented by the verified two-sequence plan and is refused instead of
     * dropping a picture or substituting a hard cut.
     */
    fun layout(
        rawInputs: List<LayoutInput>,
        dissolves: List<DissolveWindow>,
    ): CompositionLayout {
        if (rawInputs.isEmpty()) {
            throw refusal(INVALID_PAYLOAD, "A composition requires at least one video clip")
        }
        rawInputs.forEach { input ->
            if (!input.startSeconds.isFinite() || !input.endSeconds.isFinite() ||
                input.endSeconds <= input.startSeconds + 0.0001
            ) {
                throw refusal(INVALID_PAYLOAD, "A composition clip has an invalid timeline interval")
            }
        }
        val ordered = rawInputs.sortedBy { it.startSeconds }
        val lanes = ArrayList<MutableList<String>>()
        val laneEnds = ArrayList<Double>()
        val laneOf = LinkedHashMap<String, Int>()
        for (input in ordered) {
            var lane = laneEnds.indexOfFirst { end -> end <= input.startSeconds + EPSILON }
            if (lane < 0) {
                if (lanes.size >= 2) {
                    throw refusal(
                        UNSUPPORTED_TRANSITION,
                        "More than two clips overlap at once; the verified two-sequence compositor " +
                            "cannot preserve every dissolve without dropping a picture",
                    )
                }
                lane = lanes.size
                lanes.add(ArrayList())
                laneEnds.add(Double.NEGATIVE_INFINITY)
            }
            lanes[lane].add(input.clipID)
            laneOf[input.clipID] = lane
            laneEnds[lane] = max(laneEnds[lane], input.endSeconds)
        }
        val byID = ordered.associateBy { it.clipID }
        for (window in dissolves) {
            val from = byID[window.fromClipID]
                ?: throw refusal(INVALID_PAYLOAD, "A dissolve references a missing outgoing clip")
            val to = byID[window.toClipID]
                ?: throw refusal(INVALID_PAYLOAD, "A dissolve references a missing incoming clip")
            if (!window.start.isFinite() || !window.end.isFinite() || window.end <= window.start) {
                throw refusal(INVALID_PAYLOAD, "A dissolve window has invalid times")
            }
            if (laneOf[from.clipID] == laneOf[to.clipID]) {
                throw refusal(
                    UNSUPPORTED_TRANSITION,
                    "The two clips of a dissolve cannot share one compositor lane",
                )
            }
        }
        return CompositionLayout(
            lanes = lanes.map { it.toList() },
            laneOf = laneOf,
            inputs = byID,
            dissolves = dissolves,
        )
    }

    /**
     * Opacity for the clip active in [laneIndex] at composition-local
     * [seconds]. Frames from a gap or from a clip that has already ended have
     * no active clip and are fully transparent, so a held last frame or a
     * blank gap can never cover the other lane.
     */
    fun alphaAt(laneIndex: Int, seconds: Double, layout: CompositionLayout): Float {
        if (!seconds.isFinite()) return 0f
        val lane = layout.lanes.getOrNull(laneIndex) ?: return 0f
        val activeID = lane.firstOrNull { clipID ->
            val input = layout.inputs[clipID] ?: return@firstOrNull false
            seconds >= input.startSeconds - EPSILON && seconds <= input.endSeconds + EPSILON
        } ?: return 0f
        var alpha = 1.0
        for (window in layout.dissolves) {
            if (seconds < window.start - EPSILON || seconds > window.end + EPSILON) continue
            val duration = window.end - window.start
            if (duration <= 0.0) continue
            val progress = ((seconds - window.start) / duration).coerceIn(0.0, 1.0)
            val fromLane = layout.laneOf[window.fromClipID] ?: continue
            val toLane = layout.laneOf[window.toClipID] ?: continue
            when {
                activeID == window.fromClipID && fromLane < toLane ->
                    alpha = min(alpha, 1.0 - progress)
                activeID == window.toClipID && toLane < fromLane ->
                    alpha = min(alpha, progress)
            }
        }
        return alpha.coerceIn(0.0, 1.0).toFloat()
    }
}
