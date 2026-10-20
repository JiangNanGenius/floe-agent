// SPDX-License-Identifier: MPL-2.0
//
// Measured conversation detail-pane geometry (G02 host plumbing).
//
// The native authority is `ThreadDetailView.swift` (a GeometryReader around
// the whole detail surface publishes `proxy.size.height` as
// `composerHeightBudget`) plus `ThreadComposerView.swift` (fills the detail
// pane, padding 12/8, no 720pt width cap, field height capped at one third of
// the hosting page). Android previously reconstructed those values from
// `LocalConfiguration.screenWidthDp/screenHeightDp`, which is wrong when the
// same window hosts a narrower split-pane detail column.
//
// This file carries the ACTUAL measured values explicitly:
//   host wrapper (BoxWithConstraints) -> ConversationPaneGeometry
//     -> FloeConversationDestination -> ConversationComposerSection
//       -> FloeComposerLayout -> shared FloeComposer
// and the measured inline field width flows back for the expand rule.
//
// The full-editor sheet is deliberately NOT given this geometry: it is a
// separate Dialog with its own window bounds and its own IME handling. Only
// the inline overflow decision consumes `width`/`fontScale`; the sheet itself
// keeps its dialog width. Reusing the detail-pane width for the dialog would
// be a new, incorrect clamp.

package com.floe.android.feature.conversation

import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.floe.android.design.FloeComposerLayout

/**
 * Geometry of the ACTUAL conversation detail pane, measured after the host has
 * consumed the bottom system/IME inset.
 *
 * [bottomInset] and [imeBottomInset] are the raw inset values observed by the
 * host at measurement time. They are reporting fields for the binder/handoff
 * (and make the IME state explicit); [height] is already the available height
 * after the host's inset padding, so the composer must not add the inset a
 * second time ([insetsConsumedByHost]).
 *
 * A host that keeps composer-owned inset padding passes
 * `insetsConsumedByHost = false`; its [height] is then the slot height the
 * composer receives (the composer's own safeDrawing padding manages the
 * keyboard). The normal [FloeConversationPaneHost] path always consumes the
 * inset first and leaves the flag at its default `true`.
 *
 * The invariants reject non-positive pane dimensions so a zero-constraint
 * first frame can never produce a zero-height/one-third cap.
 */
@Immutable
data class ConversationPaneGeometry(
    val width: Dp,
    val height: Dp,
    val bottomInset: Dp = 0.dp,
    val imeBottomInset: Dp = 0.dp,
    val fontScale: Float = 1f,
    val insetsConsumedByHost: Boolean = true,
) {
    init {
        require(width > 0.dp) { "conversation pane width must be positive (was $width)" }
        require(height > 0.dp) { "conversation pane height must be positive (was $height)" }
        require(bottomInset >= 0.dp) { "bottomInset must be non-negative (was $bottomInset)" }
        require(imeBottomInset >= 0.dp) { "imeBottomInset must be non-negative (was $imeBottomInset)" }
        require(fontScale > 0f) { "fontScale must be positive (was $fontScale)" }
    }

    /**
     * The explicit opt-in the shared composer understands. The composer fills
     * [width] (no 720dp cap), caps its field at `[height] / 3`, and adds no
     * bottom inset padding when the host already consumed it.
     */
    fun toComposerLayout(): FloeComposerLayout = FloeComposerLayout(
        paneWidth = width,
        pageHeight = height,
        bottomInsetHandledByHost = insetsConsumedByHost,
    )
}

/**
 * Host wrapper for a real conversation detail pane.
 *
 * Use this instead of calling [FloeConversationDestination] directly when the
 * destination is embedded in the stable split view. It measures the actual
 * constraints (not the window) and consumes the bottom safe-drawing/IME inset
 * ONCE, before measuring, so:
 *  - a wide detail pane keeps the composer at the pane width;
 *  - a narrower split pane (same window) narrows it again;
 *  - rotation / split resize / font-scale change re-measure;
 *  - opening the keyboard shrinks [ConversationPaneGeometry.height] and the
 *    composer's one-third cap, with no double bottom padding.
 *
 * This composable adds no domain data and no route: the caller still owns the
 * real [ConversationFlowHolder]. The future RB7 binder replaces only the
 * placeholder branch of `FloeDetailColumn` with this wrapper.
 */
@Composable
fun FloeConversationPaneHost(
    holder: ConversationFlowHolder,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    // Consume bottom system bars + IME before BoxWithConstraints measures the
    // pane. Compose subtracts already-consumed insets, so an ancestor that
    // consumed them (for example the component fixture) is not padded twice.
    BoxWithConstraints(
        modifier = modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom)),
    ) {
        val density = LocalDensity.current
        val safeDrawing = WindowInsets.safeDrawing
        val ime = WindowInsets.ime
        val bottomInset = with(density) { safeDrawing.getBottom(this).toDp() }
        val imeBottomInset = with(density) { ime.getBottom(this).toDp() }
        val fontScale = density.fontScale
        val paneWidth = maxWidth
        val paneHeight = maxHeight
        val geometryKey = PaneGeometryKey(
            paneWidth = paneWidth,
            paneHeight = paneHeight,
            bottomInset = bottomInset,
            imeBottomInset = imeBottomInset,
            fontScale = fontScale,
        )

        val geometry = remember(geometryKey) {
            ConversationPaneGeometry(
                width = paneWidth,
                height = paneHeight,
                bottomInset = bottomInset,
                imeBottomInset = imeBottomInset,
                fontScale = fontScale,
                insetsConsumedByHost = true,
            )
        }

        FloeConversationDestination(
            holder = holder,
            modifier = Modifier.fillMaxSize(),
            onBack = onBack,
            paneGeometry = geometry,
        )
    }
}

/** Equality key for the measured pane (Compose `remember` takes max 3 keys). */
private data class PaneGeometryKey(
    val paneWidth: Dp,
    val paneHeight: Dp,
    val bottomInset: Dp,
    val imeBottomInset: Dp,
    val fontScale: Float,
)
