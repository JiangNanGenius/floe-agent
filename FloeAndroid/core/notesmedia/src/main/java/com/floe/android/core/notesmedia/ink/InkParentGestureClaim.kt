// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.ink

/** One parent-interception state change requested by an ink gesture. */
internal enum class InkParentClaimAction { CLAIM, RELEASE }

/**
 * Which router intents start or end ownership of the parent touch stream.
 * EXTEND/MOVE intents keep the current state; IGNORED never changes it.
 */
internal fun InkGestureIntent.parentClaimAction(): InkParentClaimAction? = when (this) {
    is InkGestureIntent.BeginStroke,
    is InkGestureIntent.BeginErase,
    is InkGestureIntent.TransformStart -> InkParentClaimAction.CLAIM

    is InkGestureIntent.EndStroke,
    is InkGestureIntent.EndErase,
    InkGestureIntent.TransformEnd,
    InkGestureIntent.CancelInk -> InkParentClaimAction.RELEASE

    is InkGestureIntent.ExtendStroke,
    is InkGestureIntent.ExtendErase,
    is InkGestureIntent.TransformMove,
    InkGestureIntent.Ignored -> null
}

/**
 * Tracks the single `requestDisallowInterceptTouchEvent` claim one ink gesture
 * holds on its parent.
 *
 * Compose hosts [InkCanvasView] through `pointerInteropFilter`. Without this
 * claim a scrollable page ancestor consumes the first MOVE beyond touch slop,
 * the interop layer forwards ACTION_CANCEL, and the stroke is rolled back: a
 * finger tap still commits a dot while every swipe disappears. The claim must
 * be released on stroke end, erase end, transform end, cancel, page change and
 * detach, otherwise the page can no longer scroll.
 */
internal class InkParentGestureClaim {
    private var held = false

    val isHeld: Boolean get() = held

    /**
     * Applies one router intent. Returns the new disallow-intercept value when
     * it changed, or null when the parent already has the right state.
     */
    fun apply(intent: InkGestureIntent): Boolean? = when (intent.parentClaimAction()) {
        InkParentClaimAction.CLAIM -> if (held) null else { held = true; true }
        InkParentClaimAction.RELEASE -> if (held) { held = false; false } else null
        null -> null
    }

    /** Releases any claim that is still held (page change/background/detach). */
    fun release(): Boolean? = if (held) { held = false; false } else null
}
