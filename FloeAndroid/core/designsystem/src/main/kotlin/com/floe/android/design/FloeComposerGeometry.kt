// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

import androidx.compose.runtime.Immutable
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Explicit pane geometry for the shared [FloeComposer].
 *
 * The default instance is EXACTLY the reviewed G01 behaviour: the composer
 * stays centred at a maximum of 720dp and the growing field caps at one third
 * of [androidx.compose.ui.platform.LocalConfiguration.screenHeightDp]. That
 * default exists for Home and any other shared-G01 consumer that still hosts
 * the composer against the window rather than a measured pane.
 *
 * A conversation host that embeds the composer inside an ACTUAL detail pane
 * opts in with measured values:
 *  - [paneWidth] is the width of the hosting pane. The chrome then fills that
 *    pane (minus the composer's own 12dp outer padding) instead of the 720dp
 *    reading cap. This mirrors the current native `ThreadComposerView`, which
 *    has no 720pt width cap and simply fills the full `ThreadDetailView`
 *    detail pane.
 *  - [pageHeight] is the height of the ACTUAL hosting page, not the screen.
 *    The field growth cap becomes `pageHeight / 3` (the native
 *    `composerHeightBudget` proxy value), so split panes, rotation and a
 *    keyboard-reduced pane all shrink the cap.
 *  - [bottomInsetHandledByHost] is true only when the host already consumed
 *    the bottom system/IME inset before measuring the pane. The composer then
 *    adds no bottom inset padding of its own (no double padding).
 *
 * Passing only some of the values is allowed for a host that measures a pane
 * but deliberately keeps one G01 rule; all-null is the G01 default.
 */
@Immutable
data class FloeComposerLayout(
    val paneWidth: Dp? = null,
    val pageHeight: Dp? = null,
    val bottomInsetHandledByHost: Boolean = false,
) {
    init {
        require(paneWidth == null || paneWidth > 0.dp) {
            "paneWidth must be positive when supplied (was $paneWidth)"
        }
        require(pageHeight == null || pageHeight > 0.dp) {
            "pageHeight must be positive when supplied (was $pageHeight)"
        }
    }

    /** True when at least one G01 geometry rule was replaced by measured data. */
    val isPaneOptIn: Boolean
        get() = paneWidth != null || pageHeight != null || bottomInsetHandledByHost

    companion object {
        /** Exact pre-G02 behaviour for every existing shared caller. */
        val Default = FloeComposerLayout()
    }
}

/**
 * Pure geometry helpers shared by the composer and its conversation host.
 *
 * They only combine measured pane dimensions with design-system constants;
 * they never read the window/screen size. The composer's actual inline-field
 * width is still measured by layout (`onSizeChanged`) for the overflow rule;
 * [estimatedInlineFieldWidth] exists solely for the first composition before
 * that measurement arrives.
 */
object FloeComposerGeometry {

    /** Usable chrome width inside the composer's outer horizontal padding. */
    fun chromeWidthFor(paneWidth: Dp): Dp =
        (paneWidth - FloeLayout.ComposerOuterHPadding * 2).coerceAtLeast(0.dp)

    /**
     * Native one-third page-height growth cap, floored at the Android 48dp
     * minimum target so a deliberately tiny pane still yields a valid
     * `heightIn(min, max)` constraint instead of an impossible range.
     */
    fun fieldHeightCapFor(pageHeight: Dp): Dp =
        (pageHeight / 3f).coerceAtLeast(FloeLayout.MinimumTarget)

    /**
     * Native `ComposerFieldMetrics.lineCap`: compact-width panes get six
     * visible lines, regular/tablet panes get eight. The actual pane width is
     * the input, so a narrow split column inside a wide window follows the
     * compact budget just like an iPhone-sized window.
     */
    fun inlineLineBudgetFor(paneWidth: Dp): Int =
        if (paneWidth < FloeLayout.PersistentTwoColumnMinWidth) {
            FloeLayout.ComposerMaxLinesCompact
        } else {
            FloeLayout.ComposerMaxLinesRegular
        }

    /**
     * Field slot width implied by the composer's own row before the first
     * real layout pass: chrome minus the inner horizontal padding, the visible
     * 48dp control targets and the 8dp row gaps. [visibleControlCount] is 3
     * for the idle row (attach, voice, send) and 4 while running (stop).
     *
     * This is a first-frame fallback only. The conversation section replaces
     * it with the measured field width as soon as the composer reports it.
     */
    fun estimatedInlineFieldWidth(
        paneWidth: Dp,
        visibleControlCount: Int,
    ): Dp {
        require(visibleControlCount >= 1) {
            "visibleControlCount must include the field row controls (was $visibleControlCount)"
        }
        val chromeWidth = chromeWidthFor(paneWidth)
        val controls = FloeLayout.MinimumTarget * visibleControlCount
        val gaps = FloeLayout.ComposerRowSpacing * visibleControlCount
        return (chromeWidth - FloeLayout.ComposerInnerHPadding * 2 - controls - gaps)
            .coerceAtLeast(0.dp)
    }
}
