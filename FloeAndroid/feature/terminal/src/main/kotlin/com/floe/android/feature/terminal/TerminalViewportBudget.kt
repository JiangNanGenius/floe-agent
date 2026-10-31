// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.terminal

/**
 * The terminal pane's chrome/viewport budget at one REAL measured height.
 *
 * The pane is hosted in the owning task's inspector: a fixed inspector header
 * sits above it and the tab strip, status strip, live sync hint and control row
 * sit inside it. On a tablet the soft keyboard can shrink that column to a
 * fraction of its normal height, so the fixed chrome must never be allowed to
 * consume the actual PTY surface.
 *
 * This is intentionally a pure, total description of that trade-off instead of
 * a second layout implementation:
 *  * [compact] is the single compact-chrome decision (the live sync hint is
 *    explanatory and is dropped first, the control row loses its extra
 *    vertical padding);
 *  * [showsLiveHint] keeps the hint only when the full chrome still leaves a
 *    useful viewport;
 *  * [viewportHeightDp] exposes the resulting viewport so the pane/regression
 *    can reason about it.
 *
 * Chrome heights are the REAL dp heights used by WorkspaceTerminalPane:
 * tab strip 35, status strip 36, sync hint 33, control row 60 (48dp touch
 * target + 2 x 6dp row padding). The compact control row is 52 (48 + 2 x
 * 2dp); the compact tab strip is 31 (2 x 2dp row padding). The PTY surface is
 * the weighted remainder, never a fixed pane decision.
 */
object TerminalViewportBudget {
    /** Below this pane height the auxiliary chrome is compacted. */
    const val CompactBelowDp: Float = 420f

    /** Minimum height that still shows a few real terminal rows. */
    const val MinimumUsefulViewportDp: Float = 96f

    /** Tab strip + status strip + sync hint + full control row. */
    const val FullChromeDp: Float = 35f + 36f + 33f + 60f

    /** Compact tab strip + status strip + compact control row (no hint). */
    const val CompactChromeDp: Float = 31f + 36f + 52f

    fun compact(availableHeightDp: Float): Boolean =
        availableHeightDp < CompactBelowDp

    /** Chrome height that the current pane height actually gets. */
    fun chromeHeightDp(availableHeightDp: Float): Float =
        if (compact(availableHeightDp)) CompactChromeDp else FullChromeDp

    /** Positive weighted PTY viewport after the pane's own chrome. */
    fun viewportHeightDp(availableHeightDp: Float): Float =
        (availableHeightDp - chromeHeightDp(availableHeightDp)).coerceAtLeast(0f)

    /** True only when the remaining PTY viewport is still useful. */
    fun hasUsefulViewport(availableHeightDp: Float): Boolean =
        viewportHeightDp(availableHeightDp) >= MinimumUsefulViewportDp

    /**
     * The live sync hint is explanatory; it is shown only while the FULL
     * chrome still leaves a useful viewport. It is the first auxiliary line
     * to go when the keyboard shrinks the inspector.
     */
    fun showsLiveHint(availableHeightDp: Float): Boolean =
        !compact(availableHeightDp) && hasUsefulViewport(availableHeightDp)
}
