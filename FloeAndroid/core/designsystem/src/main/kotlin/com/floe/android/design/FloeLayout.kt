// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Layout geometry mirrored from the iPad sources (research.md §1):
 * - sidebar 260/320/460 (LayoutSettings + navigationSplitViewColumnWidth)
 * - inspector 360/430/520 (FloeAgentApp.swift L841)
 * - drawer width min(390, max(300, w-44)) with 28pt continuous corners
 * - composer r22 continuous, 0.5 separator stroke, h12/v8 padding
 * - user bubble r12, h12/v8 padding
 * Android raises every interactive target to 48dp (iOS uses 44pt).
 *
 * 2026-10-18 finish-review calibration:
 * - the composer keeps the iPad's 720pt centred reading width on wide
 *   windows instead of stretching across the detail column;
 * - settings owns a 320dp navigation column (reference 03-settings) and its
 *   sheet top leaves 76pt of the masked home context visible;
 * - sidebar selection is a capsule, not a 10dp rounded rectangle.
 */
object FloeLayout {
    // Sidebar (dp, mirroring pt)
    val SidebarMinWidth = 260.dp
    val SidebarIdealWidth = 320.dp
    val SidebarMaxWidth = 460.dp

    // On-demand inspector column inside the detail pane
    val InspectorMinWidth = 360.dp
    val InspectorIdealWidth = 430.dp
    val InspectorMaxWidth = 520.dp

    /** Compact drawer: min(390, max(300, available - 44)) of the iOS idiom. */
    fun drawerWidth(availableDp: Float): Dp =
        minOf(390f, maxOf(300f, availableDp - 44f)).dp

    /**
     * A persistent two-column layout is used when the actual usable width
     * reaches a tablet boundary (not the generic 840dp cutoff). iPad mini
     * portrait (744pt) keeps its sidebar, so the boundary mirrors the
     * smallest iPad width minus tolerance for Android system bars.
     */
    val PersistentTwoColumnMinWidth = 600.dp

    /** Below this width the inspector cannot coexist with a persistent
     * sidebar + readable content, so it overlays the content column. */
    val InspectorOverlayMaxTotalWidth = 900.dp

    // Shapes
    val ComposerCorner = 22.dp
    val BubbleCorner = 12.dp
    val CardCorner = 18.dp
    val DrawerCorner = 28.dp
    val CircleToolbarCorner = 14.dp
    val ComposerStrokeWidth = 0.5.dp

    /** iOS List capsule selection (reference 01/02 New-Task row). */
    val SidebarSelectionShape: Shape = RoundedCornerShape(percent = 50)

    // Composer internals (ThreadComposerView.swift, reference 01/02)
    val ComposerInnerHPadding = 12.dp
    val ComposerInnerVPadding = 8.dp
    val ComposerOuterHPadding = 12.dp
    val ComposerOuterVPadding = 8.dp
    val ComposerControlSize = 34.dp // visual circle
    val ComposerMaxWidth = 720.dp // centred reading width from the iPad capture
    val ComposerChipHeight = 48.dp // actual Android target
    val ComposerChipVisualHeight = 32.dp // compact pill inside the target
    val ComposerMinLines = 1
    val ComposerMaxLinesCompact = 6
    val ComposerMaxLinesRegular = 8

    // Settings sheet (reference 03-settings: 320pt section column, sheet top
    // leaves the masked home toolbar visible)
    val SettingsSidebarWidth = 320.dp
    val SettingsSidebarMinWidth = 280.dp
    val SettingsSidebarMaxWidth = 360.dp
    val SettingsSheetTopInset = 76.dp

    // Hero (HomeLaunchpadView.swift L134)
    val HeroIconSize = 76.dp
    val HeroIconCorner = 18.dp
    val HeroTextGap = 16.dp

    /** Android hit-target floor (upstream Cupertino defaults to 44dp). */
    val MinimumTarget = 48.dp

    // Toolbar / chrome
    val ToolbarHeight = 52.dp
    val ToolbarButtonSize = 44.dp // visual circle; clickable box reaches MinimumTarget
    val SidebarRowHeight = 48.dp
    val SidebarRowIconSize = 24.dp
    val SettingsSheetCorner = 24.dp
    val SectionHeaderVPadding = 6.dp
}
