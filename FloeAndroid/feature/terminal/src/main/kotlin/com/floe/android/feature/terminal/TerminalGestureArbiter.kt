// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.terminal

/**
 * Pure arbitration for the terminal surface's SINGLE pointer gesture.
 *
 * The view used to run sibling tap and drag recognizers; their independent
 * consumption made "long press then drag to select" depend on dispatch order.
 * This arbiter owns the whole decision instead:
 *
 *  * before the long-press timeout, crossing the touch slop starts PAN;
 *  * at/after the long-press timeout, crossing the touch slop (or releasing
 *    without moving) is SELECTION/LongPress — never a paste;
 *  * a release without movement before the timeout is a Tap, and a second
 *    Tap inside the platform double-tap window is a DoubleTap;
 *  * once Pan/Selection starts it stays for the gesture; a cancelled gesture
 *    clears all pending tap memory.
 *
 * It has no Android/Compose dependency so the real decisions used by the
 * view are testable on the JVM. The view maps cells, applies the scroll
 * arithmetic and performs UI effects.
 */
internal class TerminalGestureArbiter(
    private val touchSlop: Float,
    private val longPressTimeoutMillis: Long,
    private val doubleTapTimeoutMillis: Long,
    private val doubleTapMinTimeMillis: Long,
) {
    enum class Mode { Undecided, Pan, Selection }

    sealed interface Release {
        data object None : Release
        data object Tap : Release
        data object DoubleTap : Release
        data object LongPress : Release
    }

    var mode: Mode = Mode.Undecided
        private set

    private var active = false
    private var downX = 0f
    private var downY = 0f
    private var downTimeMillis = 0L
    private var lastTapUptimeMillis: Long? = null

    fun down(x: Float, y: Float, timeMillis: Long) {
        mode = Mode.Undecided
        downX = x
        downY = y
        downTimeMillis = timeMillis
        active = true
    }

    /** Returns the gesture mode after this sample. Only the first sample that
     * exceeds the touch slop can change [mode]. */
    fun move(x: Float, y: Float, timeMillis: Long): Mode {
        if (active && mode == Mode.Undecided) {
            val dx = x - downX
            val dy = y - downY
            if (dx * dx + dy * dy > touchSlop * touchSlop) {
                mode = if (timeMillis - downTimeMillis >= longPressTimeoutMillis) {
                    Mode.Selection
                } else {
                    Mode.Pan
                }
            }
        }
        return mode
    }

    /** Resolves a release. Pan/Selection already acted through [move]; a
     * long press without movement selects the pressed cell in the view. */
    fun up(timeMillis: Long): Release {
        if (!active) return Release.None
        active = false
        if (mode != Mode.Undecided) {
            mode = Mode.Undecided
            lastTapUptimeMillis = null
            return Release.None
        }
        val release = when {
            timeMillis - downTimeMillis >= longPressTimeoutMillis -> Release.LongPress
            isDoubleTap(timeMillis) -> Release.DoubleTap
            else -> Release.Tap
        }
        lastTapUptimeMillis = if (release == Release.Tap) timeMillis else null
        return release
    }

    /** A gesture owned by someone else (consumed pointer or vanished id):
     * no release effect and no lingering double-tap memory. */
    fun cancel() {
        active = false
        mode = Mode.Undecided
        lastTapUptimeMillis = null
    }

    private fun isDoubleTap(timeMillis: Long): Boolean {
        val previous = lastTapUptimeMillis ?: return false
        val elapsed = timeMillis - previous
        return elapsed >= doubleTapMinTimeMillis && elapsed <= doubleTapTimeoutMillis
    }
}
