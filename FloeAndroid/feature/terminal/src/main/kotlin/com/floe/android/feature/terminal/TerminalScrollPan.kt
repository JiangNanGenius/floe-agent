// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.terminal

/**
 * Pure pixel-to-row arithmetic for finger-drag panning of the bounded
 * transcript. The view owns the gesture decision (long-press selection vs
 * plain drag panning); this helper owns only the deterministic math:
 * fractional rows carry across move events, whole rows move the viewport,
 * and the result is clamped to the real transcript.
 *
 * Positive `dragY` means the finger moved DOWN the screen. The
 * transcript is anchored at the live bottom, so dragging it down reveals
 * OLDER rows and increases [Step.scrollRows] — the same units the vendored
 * renderer (`topRow = -scrollRows`) and the accessibility viewport
 * (`G04TerminalEngine.viewportText(scrollRows)`) already consume.
 *
 * Outward motion at a bound (top or bottom) does not build hidden debt, so
 * reversing the finger responds on the first whole row.
 */
internal object TerminalScrollPan {
    data class Step(val scrollRows: Int, val carry: Float)

    fun step(
        scrollRows: Int,
        carry: Float,
        dragY: Float,
        cellHeightPx: Float,
        transcriptRows: Int,
    ): Step {
        val maxRows = transcriptRows.coerceAtLeast(0)
        val current = scrollRows.coerceIn(0, maxRows)
        val pending = if (carry.isFinite()) carry.coerceIn(-1f, 1f) else 0f
        if (maxRows == 0) return Step(0, 0f)
        if (!cellHeightPx.isFinite() || cellHeightPx <= 0f) return Step(current, pending)
        if (!dragY.isFinite()) return Step(current, pending)

        val rows = pending + dragY / cellHeightPx
        // pending and dragY can be individually finite yet overflow to
        // infinity; ignore such an event instead of scrolling arbitrarily.
        if (!rows.isFinite()) return Step(current, 0f)
        // Outward motion at a bound: no scroll and no accumulated debt.
        if ((current == 0 && rows < 0f) || (current == maxRows && rows > 0f)) {
            return Step(current, 0f)
        }
        // Bound before converting so a huge finite delta cannot overflow the
        // Int conversion; the requested value is clamped below anyway.
        val limit = (maxRows.toLong() + 1L).coerceAtMost(Int.MAX_VALUE.toLong()).toFloat()
        val bounded = rows.coerceIn(-limit, limit)
        val wholeRows = bounded.toInt()
        val requested = current.toLong() + wholeRows
        val next = requested.coerceIn(0L, maxRows.toLong()).toInt()
        val clamped = requested != next.toLong()
        return Step(next, if (clamped) 0f else rows - wholeRows)
    }
}
